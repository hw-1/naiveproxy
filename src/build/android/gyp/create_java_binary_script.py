#!/usr/bin/env python3
#
# Copyright 2014 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Creates a simple script to run a java "binary".

This creates a script that sets up the java command line for running a java
jar. This includes correctly setting the classpath and the main class.
"""

import optparse
import os
import sys

from util import build_utils

# The java command must be executed in the current directory because there may
# be user-supplied paths in the args. The script receives the classpath relative
# to the directory that the script is written in and then, when run, must
# recalculate the paths relative to the current directory.
script_template = """\
#!/usr/bin/env python3
#
# This file was generated by build/android/gyp/create_java_binary_script.py

import argparse
import os
import sys

self_dir = os.path.dirname(__file__)
classpath = [{classpath}]
extra_program_args = {extra_program_args}
java_path = {java_path}
if os.getcwd() != self_dir:
  offset = os.path.relpath(self_dir, os.getcwd())
  fix_path = lambda p: os.path.normpath(os.path.join(offset, p))
  classpath = [fix_path(p) for p in classpath]
  java_path = fix_path(java_path)
java_cmd = [java_path]
# This is a simple argparser for jvm, jar, and classpath arguments.
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--jar-args')
parser.add_argument('--jvm-args')
parser.add_argument('--classpath')
# Test_runner parses the classpath for sharding junit tests.
parser.add_argument('--print-classpath', action='store_true',
                    help='Prints the classpass. Used by test_runner.')
known_args, unknown_args = parser.parse_known_args(sys.argv[1:])

if known_args.print_classpath:
  sys.stdout.write(':'.join(classpath))
  sys.exit(0)

if known_args.jvm_args:
  jvm_arguments = known_args.jvm_args.strip('"').split()
  java_cmd.extend(jvm_arguments)
if known_args.jar_args:
  jar_arguments = known_args.jar_args.strip('"').split()
  if unknown_args:
    raise Exception('There are unknown arguments')
else:
  jar_arguments = unknown_args

if known_args.classpath:
  classpath += [known_args.classpath]

{extra_flags}
java_cmd.extend(
    ['-classpath', ':'.join(classpath), '-enableassertions', \"{main_class}\"])
java_cmd.extend(extra_program_args)
java_cmd.extend(jar_arguments)
os.execvp(java_cmd[0], java_cmd)
"""

def main(argv):
  argv = build_utils.ExpandFileArgs(argv)
  parser = optparse.OptionParser()
  parser.add_option('--output', help='Output path for executable script.')
  parser.add_option('--main-class',
      help='Name of the java class with the "main" entry point.')
  parser.add_option('--classpath', action='append', default=[],
      help='Classpath for running the jar.')
  parser.add_option('--noverify', action='store_true',
      help='JVM flag: noverify.')
  parser.add_option('--tiered-stop-at-level-one',
                    action='store_true',
                    help='JVM flag: -XX:TieredStopAtLevel=1.')

  options, extra_program_args = parser.parse_args(argv)

  extra_flags = []
  if options.noverify:
    extra_flags.append('java_cmd.append("-noverify")')
  if options.tiered_stop_at_level_one:
    extra_flags.append('java_cmd.append("-XX:TieredStopAtLevel=1")')

  classpath = []
  for cp_arg in options.classpath:
    classpath += build_utils.ParseGnList(cp_arg)

  run_dir = os.path.dirname(options.output)
  classpath = [os.path.relpath(p, run_dir) for p in classpath]
  java_path = os.path.relpath(
      os.path.join(build_utils.JAVA_HOME, 'bin', 'java'), run_dir)

  with build_utils.AtomicOutput(options.output, mode='w') as script:
    script.write(
        script_template.format(classpath=('"%s"' % '", "'.join(classpath)),
                               java_path=repr(java_path),
                               main_class=options.main_class,
                               extra_program_args=repr(extra_program_args),
                               extra_flags='\n'.join(extra_flags)))

  os.chmod(options.output, 0o750)


if __name__ == '__main__':
  sys.exit(main(sys.argv[1:]))
