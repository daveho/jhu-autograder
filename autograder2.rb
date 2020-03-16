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
# while logprivate generate output that is only visible to instructors.
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
  # Return list of files matching specified pattern in files directory.
  # This is not a task, it returns a list of the files matching the pattern.
  def self.glob(pattern)
    result = []
    IO.popen("cd #{$files} && sh -c 'ls #{pattern}'") do |f|
      f.each_line do |line|
        line.rstrip!
        result.push(line)
      end
    end
    return result
  end

  # Copy one or more files from the 'files' directory into the 'submission' directory
  def self.copy(*files)
    raise "Internal error: no file specified to copy" if files.empty?
    if files.size == 1
      # base case: copy a single file
      filename = files[0]
      return ->(outcomes, results, logger, rubric) do
        logger.log("Copying #{filename} from files...")
        rc = system('cp', "#{$files}/#{filename}", "submission")
        #logger.log("cp result is #{rc}")
        outcomes.push(rc)
      end
    else
      # recursive case: copy multiple files
      tasks = files.map { |filename| X.copy(filename) }
      return X.all(*tasks)
    end
  end

  # Check to see if a file in the submission directory exists and is executable
  def self.checkExe(filename)
    return ->(outcomes, results, logger, rubric) do
      full_filename = "submission/#{filename}"
      logger.log("Checking that #{filename} exists and is executable")
      if File.exists?(full_filename) and File.executable?(full_filename)
        outcomes.push(true)
      else
        logger.log("#{filename} doesn't exist, or is not executable")
        outcomes.push(false)
      end
    end
  end

  # Run make in the 'submission' directory
  def self.make(target)
    return ->(outcomes, results, logger, rubric) do
      raise "Internal error: submission directory is missing?" if !File.directory?('submission')
      logger.log("Running command 'make #{target}'")
      cmd = ['make', target]
      Dir.chdir('submission') do
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

  # Run a command in the 'submission' directory
  def self.run(*cmd, timeout: DEFAULT_TIMEOUT, report_command: true, report_stdout: false, report_stderr: false)
    return ->(outcomes, results, logger, rubric) do
      raise "Internal error: submission directory is missing?" if !File.directory?('submission')
      Dir.chdir('submission') do
        cmd = ['timeout', timeout.to_s ] + cmd
        logger.log("Running command: #{cmd.join(' ')}") if report_command
        stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: '')
        logger.log_cmd_output('Standard output', stdout_str, report_stdout ? :public : :private)
        logger.log_cmd_output('Standard error', stderr_str, report_stderr ? :public : :private)
        if status.success?
          outcomes.push(true)
        else
          logger.log("Command failed!")
          outcomes.push(false)
        end
      end
    end
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
