# Framework for creating Gradescope autograders

require 'open3'

########################################################################
# Resolve filenames in autograder source directory
########################################################################

def a(filename)
  if File.directory?('/autograder')
    return "/autograder/source/#{filename}"
  else
    return filename
  end
end

########################################################################
# Log to stdout
########################################################################

def log(msg)
  puts "#{Time.now.utc}: #{msg}"
end

########################################################################
# Main object model classes
########################################################################

# Generic exception type for test failures
class TestFailure < RuntimeError
  def initialize(msg)
    super(msg)
  end
end


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

  # Factory method: check that make succeeds (target is optional)
  def self.make_succeeds(rubric_item_id, *args)
    return TestMakeSucceeds.new(rubric_item_id, *args)
  end

  # Change visibility (default is true)
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

  # Add a diagnostic message.
  # If the test is visible, these messages will be
  # visible to the student.
  def add_diagnostic(msg)
    @diagnostics.push(msg)
  end

  # Set test as passed or failed depending on the value of
  # a boolean argument (true=passed, false=failed).
  def pass_if(b)
    @score = b ? @rubric_item.max_score : 0.0
  end

  # Set test as failed.
  def fail
    @score = 0.0
  end

  # Set test as failed due to an unexpected exception.
  def fail_unexpected_exception(ex)
    add_diagnostic("Test raised unexpected #{ex.class} exception, please notify instructors")
    add_diagnostic("Exception message: #{ex.message}")

    # Set the test to visible in this case, otherwise the student
    # won't see the diagnostic
    @test.visibility(true)
  end

  def to_json_obj
    return {
      'name' => @rubric_item.name,
      'score' => @score,
      'max_score' => @rubric_item.max_score,
      'output' => @diagnostics.join("\n"),
      'visibility' => @test.is_visible ? 'visible' : 'hidden'
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
    begin
      @prep.each do |prep|
        #puts "Executing preparation step #{prep.class}"
        prep.execute()
      end
      # All preparation steps succeded.
    rescue TestFailure => ex
      # Make all tests auto-fail
      wrapped_tests = []
      @members.each do |test|
        wrapped_tests.push(AutofailTest.new(test, ex.message))
      end
      @members = wrapped_tests
    rescue => ex
      # Also make all tests auto-fail, although now we're
      # dealing with something other than a TestFailure,
      # meaning it's likely to be an internal error of some kind
      wrapped_tests = []
      @members.each do |test|
        stacktrace = ex.backtrace.drop(1).join("\n")
        wrapped_tests.push(AutofailTest.new(test, "Unexpected #{ex.class} exception: #{ex.message}\n#{stacktrace}"))
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
    begin
      test.execute(self, test_result)
    rescue TestFailure => ex
      # If the test raised a TestFailure, treat that as a completely
      # failed test
      test_result.fail
      test_result.add_diagnostic("Test failed")
    rescue => ex
      # This is an unexpected exception, not good
      test_result.fail_unexpected_exception(ex)
    end
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
      if !exists
        test_result.add_diagnostic("Your submission is missing required file or files!")
      end
      count += 1 if exists
    end
    test_result.pass_if(count == @file_list.length)
  end
end

# MUnit test (https://cis.gvsu.edu/~kurmasz/Software/mipsunit_munit/).
# munit.jar must be in the autograder root directory (/autograder).
class MUnitTest < Test
  def initialize(rubric_item_id, asm_filename, testclass_filename, show_munit_output: false, timeout: 10)
    super(rubric_item_id)
    @asm_filename = asm_filename
    @testclass_filename = testclass_filename
    @show_munit_output = show_munit_output
    @timeout = timeout
  end

  def execute(autograder, test_result)
    cmd = ['timeout', @timeout.to_s, 'java', '-jar', a('munit.jar'), @asm_filename, @testclass_filename]
    log("MUnitTest: cmd=#{cmd}")
    stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: '')
    test_result.pass_if(status.success?)
    if status.exitstatus == 124
      test_result.add_diagnostic("MUnit test timed out after #{@timeout} seconds")
    elsif status.success?
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

class TestMakeSucceeds < Test
  def initialize(rubric_item_id, *args)
    super(rubric_item_id)
    @args = args
  end

  def execute(autograder, test_result)
    cmd = ['make']
    @args.each { |arg| cmd.push(arg) }
    test_result.add_diagnostic("Running command: #{cmd.join(' ')}")
    Dir.chdir('submission') do
      stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: '')
      test_result.add_diagnostic('')
      stdout_str.split('\n').each do |line|
        test_result.add_diagnostic(line)
      end
      if !stderr_str.empty?
        test_result.add_diagnostic('')
        test_result.add_diagnostic('Error output:')
        stderr_str.split('\n').each do |line|
          test_result.add_diagnostic(line)
        end
      end
      test_result.pass_if(status.success?)
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

  def execute
    #puts "run_command: cmd=#{@cmd}, input=#{@input}, output=#{@output}"
    raise "run_command missing command" if @cmd.nil?
    @input = '/dev/null' if @input.nil?

    # Run the command
    begin
      input_data = File.read(@input)
      stdout_str, stderr_str, status = Open3.capture3(*@cmd, stdin_data: input_data)
      #puts "stdout_str=#{stdout_str}"
    rescue => ex
      # Report an exception here as a TestFailure: if the
      # tests are properly written, prep commands shouldn't
      # fail (and in general, there's no inherent way
      # of knowing whose fault the failure is.)
      raise TestFailure.new("Command #{@cmd} failed: #{ex.message}")
    end

    # Check to see whether the command was successful
    if !status.success?
      #raise "#{cmd[0]} command failed"
      # Same deal as earlier: treat this as a test failure
      raise TestFailure.new("Command #{@cmd} failed: #{ex.message}")
    end

    log("run_command: success?")

    # If output was redirected to file, write it
    if !@output.nil?
      File.open(@output, 'w') do |outf|
        outf.write(stdout_str)
      end
    end
  end
end
