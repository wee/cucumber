require 'cucumber/step_match'

module Cucumber
  module Ast
    class StepInvocation #:nodoc:
      INDENT = 2

      BACKTRACE_FILTER_PATTERNS = [
        /vendor\/rails|lib\/cucumber|bin\/cucumber:|lib\/rspec|gems\//
      ]

      attr_writer :background
      attr_reader :name, :keyword, :line, :status, :reported_exception, :multiline_arg
      attr_accessor :exception

      def initialize(prev, feature_element, keyword, name, line, matched_cells)
        @prev, @feature_element, @keyword, @name, @line, @matched_cells = 
          prev, feature_element, keyword, name, line, matched_cells
        status!(:skipped)
      end

      def from_cells(prev, cells)
        matched_cells = matched_cells(cells)

        delimited_arguments = delimit_argument_names(cells.to_hash)
        name                = replace_name_arguments(delimited_arguments)
        multiline_arg       = @multiline_arg.nil? ? nil : @multiline_arg.arguments_replaced(delimited_arguments)
        self.class.new(prev, @feature_element, @keyword, name, @line, matched_cells)
      end

      def set_multiline_string(string, line)
        @multiline_arg = PyString.new(string)
      end

      def background?
        @background
      end

      def skip_invoke!
        @skip_invoke = true
      end

      def accept(visitor)
        return if $cucumber_interrupted
        if ScenarioOutline === @feature_element
          @step_match = first_match_from_examples(visitor.step_mother)
        else
          invoke(visitor.step_mother, visitor.options)
        end
        visit_step_result(visitor)
      end

      def visit_step_result(visitor)
        visitor.visit_step_result(keyword, @step_match, @multiline_arg, @status, @reported_exception, source_indent, @background)
      end

      def invoke(step_mother, options)
        find_step_match!(step_mother)
        unless @skip_invoke || options[:dry_run] || @exception #|| @step_collection.exception
          @skip_invoke = true
          begin
            @step_match.invoke(@multiline_arg)
            step_mother.after_step
            status!(:passed)
          rescue Pending => e
            failed(options, e, false)
            status!(:pending)
          rescue Undefined => e
            failed(options, e, false)
            status!(:undefined)
          rescue Exception => e
            failed(options, e, false)
            status!(:failed)
          end
        end
      end

      def find_step_match!(step_mother)
        return if @step_match
        begin
          @step_match = step_mother.step_match(@name)
        rescue Undefined => e
          failed(step_mother.options, e, true)
          status!(:undefined)
          @step_match = NoStepMatch.new(self, @name)
        rescue Ambiguous => e
          failed(step_mother.options, e, false)
          status!(:failed)
          @step_match = NoStepMatch.new(self, @name)
        end
        step_mother.step_visited(self)
      end

      def failed(options, e, clear_backtrace)
        e = filter_backtrace(e)
        e.set_backtrace([]) if clear_backtrace
        e.backtrace << backtrace_line unless backtrace_line.nil?
        @exception = e
        if(options[:strict] || !(Undefined === e) || e.nested?)
          @reported_exception = e
        else
          @reported_exception = nil
        end
      end

      def filter_backtrace(e)
        return e if Cucumber.use_full_backtrace
        filtered = (e.backtrace || []).reject do |line|
          BACKTRACE_FILTER_PATTERNS.detect { |p| line =~ p }
        end
        
        if Cucumber::JRUBY && e.class.name == 'NativeException'
          # JRuby's NativeException ignores #set_backtrace.
          # We're fixing it.
          e.instance_eval do
            def set_backtrace(backtrace)
              @backtrace = backtrace
            end

            def backtrace
              @backtrace
            end
          end
        end
        e.set_backtrace(filtered)
        e
      end

      def status!(status)
        @status = status
        @matched_cells.each do |cell|
          cell.status = status
        end
      end

      def actual_keyword
        repeat_keywords = [language.but_keywords, language.and_keywords].flatten
        if repeat_keywords.index(@keyword) && @prev
          @prev.actual_keyword
        else
          keyword
        end
      end

      def language
        @feature_element.language
      end

      def source_indent
        @feature_element.source_indent(text_length)
      end

      def text_length(name=@name)
        @keyword.jlength + name.jlength + INDENT # Add indent as steps get indented more than scenarios
      end

      def file_colon_line
        @file_colon_line ||= @feature_element.file_colon_line(@line) unless @feature_element.nil?
      end

      def dom_id
        @step.dom_id
      end

      def backtrace_line
        @backtrace_line ||= @feature_element.backtrace_line("#{@keyword} #{@name}", @line) #unless @feature_element.nil?
      end

      private

      def first_match_from_examples(step_mother)
        # @feature_element is always a ScenarioOutline in this case
        @feature_element.each_example_row do |cells|
          argument_hash       = cells.to_hash
          delimited_arguments = delimit_argument_names(argument_hash)
          name                = replace_name_arguments(delimited_arguments)
          step_match          = step_mother.step_match(name, @name) rescue nil
          return step_match if step_match
        end
        NoStepMatch.new(self, @name)
      end

      def matched_cells(cells)
        col_index = 0
        cells.select do |cell|
          header_cell = cell.table.header_cell(col_index)
          col_index += 1
          delimited = delimited(header_cell.value)
          @name.index(delimited) || (@multiline_arg && @multiline_arg.has_text?(delimited))
        end
      end

      def delimited(s)
        "<#{s}>"
      end

      def delimit_argument_names(argument_hash)
        argument_hash.inject({}) { |h,(name,value)| h[delimited(name)] = value; h }
      end

      def replace_name_arguments(argument_hash)
        name_with_arguments_replaced = @name
        argument_hash.each do |name, value|
          value ||= ''
          name_with_arguments_replaced = name_with_arguments_replaced.gsub(name, value) if value
        end
        name_with_arguments_replaced
      end
    end
  end
end