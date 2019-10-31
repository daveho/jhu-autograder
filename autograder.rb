# Framework for creating Gradescope autograders

########################################################################
# Main object model classes.
########################################################################

# Rubric: collection of RubricItems
class Rubric
  attr_reader :items

  def initialize
    @items = []
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
    @tests.each do |test|
      rubric_item = @rubric.lookup_item(test.rubric_item_id)
      test_result = TestResult.new(test, rubric_item)
      test.execute(self, test_result)
      @test_results.push(test_result)
    end

    report = { 'tests' => [] }
    @test_results.each do |test_result|
      report['tests'].push(test_result.to_json_obj)
    end
    return report
  end

  # Execute a block in the submission directory
  def in_submission_dir
    begin
      Dir.chdir('submission')
      yield
    ensure
      Dir.chdir('..')
    end
  end
end

########################################################################
# Test implementation classes
########################################################################

class TestCheckFiles < Test
  def initialize(rubric_item_id, file_list)
    super(rubric_item_id)
    @file_list = file_list
  end

  def execute(autograder, test_result)
    count = 0
    autograder.in_submission_dir do
      @file_list.each do |filename|
        exists = File.file?(filename)
        test_result.add_diagnostic("#{filename} exists: #{exists}")
        count += 1 if exists
      end
    end
    test_result.pass_if(count == @file_list.length)
  end
end
