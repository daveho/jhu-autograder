# Gradescope autograder framework

**Note**: this repository is deprecated and will not be updated.
Please see <https://github.com/daveho/declarative-autograder> for the
most recent version of the autograder framework.

This is an experiment to create a general-purpose framework for implementing
[Gradescope](https://www.gradescope.com/) autograders.  (You should read
the [Gradescope autograder specification](https://gradescope-autograders.readthedocs.io/en/latest/specs/) for more information about how they work.

[autograder2.rb](autograder2.rb) is a result of this experiment.  There is
no documentation or example code yet (TODO, coming soon), but it works pretty
well and supports *very* clean `run_autograder` scripts.

[autograder.rb](autograder.rb) was the initial effort, and was a useful learning
experience, but the API was too ad-hoc and difficult to use.  I'm leaving it
here for now only because it contains some useful code that hasn't been ported
over to [autograder2.rb](autograder2.rb) yet.

The code is distributed under the MIT license.  Comments to <mailto:david.hovemeyer@gmail.com>
