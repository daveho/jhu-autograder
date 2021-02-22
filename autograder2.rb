# Flexible Gradescope autograder framework
# Copyright (c) 2019,2020 David H. Hovemeyer <david.hovemeyer@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION

# Goal is to allow "declarative" autograders, where the run_autograder
# script specifies a WHAT is tested, not HOW the testing is done

require 'open3'
require 'json'

# Figure out where files are. For local testing, we assume 'files'
# is in the same directory as 'run_autograder', but on the actual
# Gradescope VM, it will be a subdirectory of 'source'.
$files = 'files'
if !File.directory?('files') and File.directory?('source/files')
  $files = 'source/files'
end

# Default timeout for executed commands
DEFAULT_TIMEOUT = 20

# Default subprocess success predicate
DEFAULT_SUCCESS_PRED = ->(status, stdout_str, stderr_str) do
  return status.success?
end

# Wrapper class for rubric, simplifies lookup of item by testname
class Rubric
  attr_reader :spec

  def initialize(spec)
    @spec = spec
  end

  def get_desc(testname)
    @spec.each do |tuple|
      return tuple[1] if tuple[0] == testname
    end
    raise "Internal error: unknown testname #{testname}"
  end
end

# Logger: student-visible test output is generated with log,
# while logprivate generates output that is only visible to instructors.
# log_cmd_output generates either public or private output,
# depending on the value of its visibility parameter.
class Logger
  def initialize
    @msgs = []
  end

  # Send a message to the private log visible only to instructors
  def logprivate(msg)
    # Print to stdout so the message is reported to instructors by Gradescope
    puts "#{Time.now.utc}: #{msg}"
  end

  # Log command output (stdout or stderr) to the reported diagnostics
  # Parameters:
  #   kind - what kind of output: each emitted line is prefixed with this string
  #   output - output to log
  #   visibility - either :public or :private
  def log_cmd_output(kind, output, visibility)
    logfn = ->(msg) { visibility == :public ? log(msg) : logprivate(msg) }
    logfn.call("#{kind}:")
    output.split("\n").each do |line|
      logfn.call(line)
    end
  end

  # Save a message to be reported to student as part of test result
  def log(msg)
    # Send to private log
    logprivate(msg)
    # Save message: will be made part of reported test result
    @msgs.push(msg)
  end

  # Get all logged messages (returning a copy to avoid mutation issues)
  def get_msgs
    return @msgs.clone
  end

  # Clear out accumulated log messages
  # (this should be done once a test result is reported)
  def clear
    @msgs.clear
  end
end

# Tasks
# must support a call method with the following parameters
#   outcomes: list of booleans containing previous test results
#   results: map of testnames to scores (for reporting)
#   logger: for logging diagnostics
#   rubric: the rubric describing the tests
# in general, tasks can (and should) be lambdas

class X
  # Build an array consisting of all arguments as elements, with the
  # exception that arguments that are arrays will have their elements
  # added.  This is useful for building a large argument array
  # out of an arbitrary combination of arrays and individual values.
  def self.combine(*args)
    result = []
    args.each do |arg|
      if arg.kind_of?(Array)
        result.concat(arg)
      else
        result.push(arg)
      end
    end
    return result
  end

  # Return list of files matching specified pattern in files directory.
  # This is not a task, it returns a list of the files matching the pattern.
  def self.glob(pattern)
    result = []
    IO.popen("cd #{$files} && sh -c 'ls -d #{pattern}'") do |f|
      f.each_line do |line|
        line.rstrip!
        result.push(line)
      end
    end
    return result
  end

  # Copy one or more files from the 'files' directory into the 'submission' directory
  #
  # Options:
  #   subdir: if specified, files are copied into this subdirectory of submission
  #   report_command: if true, command is reported to student (defaults to true)
  def self.copy(*files, subdir: nil, report_command: true)
    raise "Internal error: no file specified to copy" if files.empty?
    if files.size == 1
      # base case: copy a single file
      filename = files[0]
      destdir = subdir.nil? ? 'submission' : "submission/#{subdir}"
      return ->(outcomes, results, logger, rubric) do
        logger.log("Copying #{filename} from files...") if report_command
        rc = system('cp', "#{$files}/#{filename}", destdir)
        #logger.log("cp result is #{rc}")
        outcomes.push(rc)
      end
    else
      # recursive case: copy multiple files
      tasks = files.map { |filename| X.copy(filename, subdir: subdir, report_command: report_command) }
      return X.all(*tasks)
    end
  end

  # Recursively copy one or more entire directories from the 'files' directory into the 'submission' directory
  def self.copydir(*dirnames)
    raise "Internal error: no directory specified to copy" if dirnames.empty?
    if dirnames.size == 1
      # base case: copy a single directory
      dirname = dirnames[0]
      return ->(outcomes, results, logger, rubric) do
        logger.log("Copying directory #{dirname} from files...")
        rc = system('cp', '-r', "#{$files}/#{dirname}", "submission")
        outcomes.push(rc)
      end
    else
      # recursive case: copy multiple directories
      tasks = dirnames.map { |dirname| X.copydir(dirname) }
      return X.all(*tasks)
    end
  end

  # Check to see if files in the submission directory exist.
  # Task will produce a true outcome IFF all of the files exist.
  #
  # Options:
  #   check_exe: if true, also check that file(s) are executable (default false)
  #   subdir: if set, file(s) are checked in specified subdirectory of 'submission'
  def self.check(*filenames, check_exe: false, subdir: nil)
    return ->(outcomes, results, logger, rubric) do
      checkdir = subdir.nil? ? 'submission' : "submission/#{subdir}"
      checks = []
      filenames.each do |filename|
        full_filename = "#{checkdir}/#{filename}"
        logger.log("Checking that #{filename} exists#{check_exe ? ' and is executable' : ''}")
        if File.exists?(full_filename) and (!check_exe || File.executable?(full_filename))
          checks.push(true)
        else
          logger.log("#{filename} doesn't exist#{check_exe ? ', or is not executable' : ''}")
          checks.push(false)
        end
      end
      outcomes.push(checks.all?)
    end
  end

  # Check to see if files in the submission directory exist and are executable.
  # Task will produce a true outcome IFF all of the files exist and are executable.
  def self.check_exe(*filenames, subdir: nil)
    return check(*filenames, check_exe: true, subdir: subdir)
  end

  # Use the check_exe function instead: this is just here for backwards
  # compatibility.
  def self.checkExe(*filenames, subdir: nil)
    return check_exe(*filenames, subdir: subdir)
  end

  # Run make in the 'submission' directory (or a specified subdirectory).
  # Parameters passed to this task are passed as command-line arguments
  # to make.  With no arguments, the default target will be built.
  #
  # Options:
  #   subdir: if specified, make is run in this subdirectory of 'submission'
  def self.make(*makeargs, subdir: nil)
    return ->(outcomes, results, logger, rubric) do
      # Determine where to run make
      cmddir = subdir.nil? ? 'submission' : "submission/#{subdir}"

      # Make sure the directory actually exists
      raise "Internal error: #{cmddir} directory is missing?" if !File.directory?(cmddir)

      cmd = ['make'] + makeargs
      logger.log("Running command #{cmd.join(' ')}")
      Dir.chdir(cmddir) do
        stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: '')
        if status.success?
          logger.log("Successful make")
          logger.log_cmd_output('Make standard output', stdout_str, :private)
          logger.log_cmd_output('Make standard error', stderr_str, :private)
          outcomes.push(true)
        else
          logger.log("Make failed!")
          logger.log_cmd_output('Make standard output', stdout_str, :public)
          logger.log_cmd_output('Make standard error', stderr_str, :public)
          outcomes.push(false)
        end
      end
    end
  end

  # Run a command in the 'submission' directory (or a specified subdirectory).
  #
  # Options:
  #   timeout: timeout in seconds
  #   report_command: report the executed command to student, defaults to true
  #   report_stdout: report command stdout to student, defaults to false
  #   report_stderr: report command stderr to student, defaults to false
  #   report_outcome: report "Command failed!" if command fails, defaults to true
  #   stdin_filename: name of file to send to command's stdin, defaults to nil (meaning empty stdin is sent)
  #   stdout_filename: name of file to write command's stdout to (in the submission directory),
  #                    defaults to nil (meaning that stdout is not written anywhere)
  #   subdir: if specified, the command is run in this subdirectory of 'submission'
  #   env: if specified, hash with additional environment variables to set for subprocess
  #   success_pred: predicate to check subprocess success: must have a call method that
  #                 takes process status object, standard output string, and
  #                 standard error string as parameters, defaults to just checking
  #                 status.success?
  #
  # Note that if stdin_filename is specified, its entire contents are read into memory.
  def self.run(*cmd,
               timeout: DEFAULT_TIMEOUT,
               report_command: true,
               report_stdout: false,
               report_stderr: false,
               report_outcome: true,
               stdin_filename: nil,
               stdout_filename: nil,
               subdir: nil,
               env: {},
               success_pred: DEFAULT_SUCCESS_PRED)
    return ->(outcomes, results, logger, rubric) do
      # Determine where to run the command
      cmddir = subdir.nil? ? 'submission' : "submission/#{subdir}"

      # Make sure the directory actually exists
      raise "Internal error: #{cmddir} directory is missing?" if !File.directory?(cmddir)

      Dir.chdir(cmddir) do
        stdin_data = stdin_filename.nil? ? '' : File.read(stdin_filename, binmode: true)
        cmd = ['timeout', timeout.to_s ] + cmd
        #puts "report_command=#{report_command}"
        logger.log("Running command: #{cmd.join(' ')}") if report_command
        stdout_str, stderr_str, status = Open3.capture3(env, *cmd, stdin_data: stdin_data, binmode: true)
        logger.log_cmd_output('Standard output', stdout_str, report_stdout ? :public : :private)
        logger.log_cmd_output('Standard error', stderr_str, report_stderr ? :public : :private)
        if !stdout_filename.nil?
          File.open(stdout_filename, 'wb') do |outfh|
            outfh.write(stdout_str)
          end
        end
        if success_pred.call(status, stdout_str, stderr_str)
          outcomes.push(true)
        else
          logger.log("Command failed!") if report_outcome
          outcomes.push(false)
        end
      end
    end
  end

  class Pred
    attr_accessor :pred_func, :desc

    def initialize(pred_func, desc)
      @pred_func = pred_func
      @desc = desc
    end

    def call(*args)
      return @pred_func.call(*args)
    end
  end

  # Create a predicate from a lambda and a string with a textual
  # description of the predicate being evaluated.
  # The lambda should take one parameter, the results map.
  # When creating an eval_pred task, using this function to create
  # a predicate is preferred to just using a lambda because it allows
  # the task to generate a meaningful student-visible log message
  # describing what the predicate is evaluating.
  def self.pred(pred_func, desc)
    return Pred.new(pred_func, desc)
  end

  # A task that evaluates a predicate and produces an outcome
  # based on the result (true or false) of that predicate.
  # This is useful for "synthetic" tests, i.e., ones whose outcomes
  # aren't based by executing student code, but instead are evaluated
  # by other criteria.  The "pred" parameter must have a "call"
  # function which takes one parameter --- the results map, which
  # allows the predicate to know whether previous tests have passed
  # or failed --- and returns true or false.
  # Suggestion: use the "pred" function to create the predicate,
  # which will allow it to have a meaningful description that can be
  # logged.
  #
  # Options:
  def self.eval_pred(pred, report_desc: true, report_outcome: true)
    return ->(outcomes, results, logger, rubric) do
      if pred.respond_to?(:desc) && report_desc
        logger.log("Checking predicate: #{pred.desc}")
      end
      outcome = pred.call(results)
      if report_outcome
        logger.log("Predicate evaluated as #{outcome}")
      end
      outcomes.push(outcome)
    end
  end

  # Check whether a test passed.
  # Requires that the results map is available.
  # This can be called from within a predicate function,
  # since the results map will be (at least partially) available by
  # that time.
  def self.test_passed(testname, results)
    if !results.has_key?(testname)
      return false
    end
    result_pair = results[testname]
    return result_pair[0] >= 1.0
  end

  # Run a task as a test.
  # The success or failure of the test will be reported.
  def self.test(testname, task)
    return ->(outcomes, results, logger, rubric) do
      logger.log("Executing test: #{rubric.get_desc(testname)}")
      task.call(outcomes, results, logger, rubric)
      # Report on success or failure
      if outcomes[-1]
        logger.log("Test PASSED")
        results[testname] = [ 1.0, logger.get_msgs ]
      else
        logger.log("Test FAILED")
        results[testname] = [ 0.0, logger.get_msgs ]
      end
      logger.clear
    end
  end

  # Execute all tasks in sequence, auto-failing any tasks that follow
  # a failed task. A single outcome is reported: true if all tasks succeeded,
  # false if any tasks failed.
  def self.all(*tasks)
    return ->(outcomes, results, logger, rubric) do
      task_outcomes = []
      any_failed = false

      # Execute the individual tasks
      tasks.each do |task|
        if any_failed
          # This task gets auto-failed
          task_outcomes.push(false)
          #logger.log("Auto-failing task, yo")
        else
          num_outcomes = task_outcomes.size
          task.call(task_outcomes, results, logger, rubric)
          raise "Internal error: task failed to generate an outcome" if task_outcomes.size < num_outcomes + 1
          any_failed = !task_outcomes[-1]
          raise "Internal error: task generated a non-boolean outcome" if not ([true,false].include?(any_failed))
          logger.log("Task failed, not executing subsequent tasks") if any_failed
        end
      end

      # If all of the individual tasks succeeded, then the overall 'all' task has succeeded
      outcomes.push(task_outcomes.all?)
      #logger.log("all task outcome: #{outcomes[-1]}")
    end
  end

  # Execute all tasks in sequence and record their outcomes.
  def self.inorder(*tasks)
    return ->(outcomes, results, logger, rubric) do
      tasks.each do |task|
        task.call(outcomes, results, logger, rubric)
      end
    end
  end

  # Execute all tasks in sequence and record their outcomes, but
  # change all of the outcomes to true, creating the illusion that
  # all tests succeed even if they didn't.
  def self.nofail(*tasks)
    return ->(outcomes, results, logger, rubric) do
      tasks.each do |task|
        task.call(outcomes, results, logger, rubric)
      end
      outcomes.map! { true }
    end
  end

  # Execute one task and expect it to fail.
  # The "inverted" task succeeds if the original task fails,
  # and vice versa.
  def self.expectfail(task)
    return ->(outcomes, results, logger, rubric) do
      task.call(outcomes, results, logger, rubric)
      outcomes.map! { |b| !b }
    end
  end

  def self._visibility_of(testname)
    return testname.to_s.end_with?('_hidden') ? 'hidden' : 'visible'
  end

  def self.result_obj_for_missing_test(testname, desc, maxscore)
    return {
      'name' => desc,
      'score' => 0.0,
      'max_score' => maxscore,
      'output' => 'Test was not executed due to a failed prerequisite step',
      'visibility' => _visibility_of(testname)
    }
  end

  def self.result_obj(testname, desc, maxscore, outcome_pair)
    return {
      'name' => desc,
      'score' => outcome_pair[0] * maxscore,
      'max_score' => maxscore,
      'output' => outcome_pair[1].join("\n"),
      'visibility' => _visibility_of(testname)
    }
  end

  # Execute the tests and return a hash that can be converted into a
  # results JSON file
  def self.execute_tests(rubric, plan)
    rubric = Rubric.new(rubric)
    logger = Logger.new

    # results is a map of testnames to earned scores
    results = {}

    # execute the plan
    outcomes = []
    plan.call(outcomes, results, logger, rubric)

    # prepare the report
    results_json = { 'tests' => [] }

    rubric.spec.each do |tuple|
      testname, desc, maxscore = tuple
      if !results.has_key?(testname)
        # no result was reported for this testname
        # this is *probably* because the associated test depended on a prerequisite task that failed
        results_json['tests'].push(result_obj_for_missing_test(testname, desc, maxscore))
      else
        outcome_pair = results[testname]
        results_json['tests'].push(result_obj(testname, desc, maxscore, outcome_pair))
      end
    end

    return results_json
  end

  # Write generated JSON results object to correct location to report
  # autograder results to Gradescope
  def self.post_results(results_json)
    system('mkdir -p results')
    File.open("results/results.json", 'w') do |outf|
      outf.puts JSON.pretty_generate(results_json)
    end
  end
end

# vim:ft=ruby:
