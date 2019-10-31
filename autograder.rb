# Framework for creating Gradescope autograders

require 'open3'

########################################################################
# Main object model classes
########################################################################

# Rubric: collection of RubricItems
class Rubric
  attr_reader :items

  def initialize(items: [])
    @items = items
  end

  def add(item)
    @items.push(item)
  end

  def lookup_item(item_id)
    @items.each do |item|
      return item if item.id == item_id
    end
    raise "Unknown rubric item id: #{item_id}"
  end
end

# RubricItem: chunk of credit that can be earned.
# The "id" attribute is a unique id value (ideally a symbol)
# identifying the item.  The name is a human-readable
# explanation of the correctness criterion the RubricItem
# represents.
class RubricItem
  attr_reader :id, :name, :max_score

  def initialize(id, name, max_score)
    @id = id
    @name = name
    @max_score = max_score
  end
end

# Test: a test against the submitted code that can earn
# partial or full credit for a specified RubricItem
# (identified by its unique id).  Can be executed to produce
# a TestResult.
class Test
  attr_reader :rubric_item_id, :is_visible

  # Don't directly instantiate a Test: use one of the factory methods.
  def initialize(rubric_item_id)
    @rubric_item_id = rubric_item_id
    @is_visible = true
  end

  # Factory method: check that specified files are present in the
  # submission directory.
  def self.check_files(rubric_item_id, file_list)
    return TestCheckFiles.new(rubric_item_id, file_list)
  end

  # Set visibility to false
  def visibility(b)
    @is_visible = b
    return self
  end
end

# TestResult: the outcome of executing a Test,
# can contain diagnostics and other information about
# the test outcome, and indicates the earned score
# with respect to the Test's corresponding RubricItem
class TestResult
  attr_reader :test, :rubric_item, :diagnostics, :score

  def initialize(test, rubric_item)
    @test = test
    @diagnostics = []
    @rubric_item = rubric_item
    @score = 0.0
  end

  def add_diagnostic(msg)
    @diagnostics.push(msg)
  end

  def pass_if(b)
    @score = b ? @rubric_item.max_score : 0.0
  end

  def fail
    @score = 0.0
  end

  def to_json_obj
    return {
      'name' => @rubric_item.name,
      'score' => @score,
      'max_score' => @rubric_item.max_score,
      'output' => @diagnostics.join("\n"),
      'visibility' => @test.is_visible
    }
  end
end

class AutofailTest < Test
  def initialize(test, fail_msg)
    super(test.rubric_item_id)
    @fail_msg = fail_msg
  end

  def execute(autograder, test_result)
    #puts "Autofailing!"
    test_result.add_diagnostic(@fail_msg)
    test_result.fail
  end
end

class TestGroup
  attr_reader :members

  def initialize(prep: [], tests: [])
    @prep = prep
    @members = tests
  end

  def prepare
    prep_msgs = []
    begin
      @prep.each do |prep|
        #puts "Executing preparation step #{prep.class}"
        prep.execute(prep_msgs)
      end
      # All preparation steps succeded.
      # Could do something with prep_msgs, although
      # they're not really part of a specific test.
    rescue => ex

      # Make all tests auto-fail
      wrapped_tests = []
      @members.each do |test|
        wrapped_tests.push(AutofailTest.new(test, prep_msgs.last))
      end
      @members = wrapped_tests
    end
  end
end

# Autograder: object for orchestrating the overall autograder
# execution
class Autograder
  attr_reader :rubric, :tests, :test_results

  def initialize(rubric, tests)
    @rubric = rubric
    @tests = tests
    @test_results = []
  end

  def execute
    # if the /autograder directory exists, chdir to it,
    # otherwise just stay where we are (e.g., for local testing)
    if File.directory?('/autograder')
      Dir.chdir('/autograder')
    end

    @tests.each do |test|
      if test.is_a?(TestGroup)
        # Test group: execute preparation step(s), then execute
        # all tests.  Note that tests will auto-fail themselves if
        # any preparation step(s) failed.
        test.prepare
        test.members.each do |test|
          execute_test(test)
        end
      else
        # Just executing one standalone test
        execute_test(test)
      end
    end

    report = { 'tests' => [] }
    @test_results.each do |test_result|
      report['tests'].push(test_result.to_json_obj)
    end
    return report
  end

  def execute_test(test)
    rubric_item = @rubric.lookup_item(test.rubric_item_id)
    test_result = TestResult.new(test, rubric_item)
    test.execute(self, test_result)
    @test_results.push(test_result)
  end
end

# Factory to create preparation steps for a TestGroup
class Prep
  # Run specific command, allowing redirection to/from files
  def self.run_command(cmd: nil, input: nil, output: nil)
    return RunCommand.new(cmd, input, output)
  end
end

########################################################################
# Test implementation classes
########################################################################

# Check that required files are present in the submission directory.
class TestCheckFiles < Test
  def initialize(rubric_item_id, file_list)
    super(rubric_item_id)
    @file_list = file_list
  end

  def execute(autograder, test_result)
    count = 0
    @file_list.each do |filename|
      exists = File.file?("submission/#{filename}")
      test_result.add_diagnostic("#{filename} exists: #{exists}")
      count += 1 if exists
    end
    test_result.pass_if(count == @file_list.length)
  end
end

# MUnit test (https://cis.gvsu.edu/~kurmasz/Software/mipsunit_munit/).
# munit.jar must be in the autograder root directory (/autograder).
class MUnitTest < Test
  def initialize(rubric_item_id, asm_filename, testclass_filename, show_munit_output: false)
    super(rubric_item_id)
    @asm_filename = asm_filename
    @testclass_filename = testclass_filename
    @show_munit_output = show_munit_output
  end

  def execute(autograder, test_result)
    cmd = ['java', '-jar', 'munit.jar', @asm_filename, @testclass_filename]
    stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: '')
    test_result.pass_if(status.success?)
    if status.success?
      test_result.add_diagnostic("MUnit test #{@testclass_filename} passed")
    else
      test_result.add_diagnostic("MUnit test #{@testclass_filename} failed")
      if @show_munit_output
        test_result.add_diagnostic('')
        stdout_str.split('\n').each do |line|
          test_result.add_diagnostic(line)
        end
      end
    end
  end
end

########################################################################
# Preparation steps initialization
########################################################################

class RunCommand
  def initialize(cmd, input, output)
    @cmd = cmd
    @input = input
    @output = output
  end

  def execute(prep_msgs)
    #puts "run_command: cmd=#{@cmd}, input=#{@input}, output=#{@output}"
    prep_msgs.push("Running command #{@cmd}")
    raise "run_script missing command" if @cmd.nil?
    @input = '/dev/null' if @input.nil?

    # Run the command
    begin
      input_data = File.read(@input)
      stdout_str, stderr_str, status = Open3.capture3(*@cmd, stdin_data: input_data)
      #puts "stdout_str=#{stdout_str}"
    rescue => ex
      prep_msgs.push("Command #{@cmd} failed: #{ex.message}")
      raise "#{cmd[0]} failed"
    end

    # Check to see whether the command was successful
    if !status.success?
      prep_msgs.push("Command #{cmd} failed")
      raise "#{cmd[0]} command failed"
    end
    # If output was redirected to file, write it
    if !@output.nil?
      File.open(@output, 'w') do |outf|
        outf.write(stdout_str)
      end
    end
  end
end
