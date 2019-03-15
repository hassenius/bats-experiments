#!/usr/bin/env bash

#Set work dir
export sert_bats_workdir="$(dirname "$($(type -p greadlink readlink | head -1) -f  "$BASH_SOURCE")")"

# Setup even if not explicitly declared in *.bats cases
IMPLICIT_CAPABILITIES=(  )

# If disabled the assumption is that everything
# kubectl, namespace, etc is setup beforehand
PREINSTALL_PREREQS=${PREINSTALL_PREREQS:-true}

# Where groups of test cases can be found
TEST_SUITE_ROOT=${TEST_SUITE_ROOT:-${sert_bats_workdir}/suites}

# Set to true to have separate bats runs per group
GROUP_RUNS=${GROUP_RUNS:-false}

# Skip of fail tests if environment setup for the cases fails
export ON_SETUP_FAIL="${ON_SETUP_FAIL:-fail}"

# Fail subsequent tests in case when a test fails.
# This is typically not default behaviour but useful for end-to-end tests
export FAIL_SUBSEQUENT_TESTS="false"

source $sert_bats_workdir/helpers.bash


run_bats() {
  ####
  # Setup the output format
  ####
  if [ X$OUTPUT_FORMAT == 'Xjunit' ]; then
      output_format="-u"
  elif [ X$OUTPUT_FORMAT == 'Xtap' ]; then
      output_format="-t"
  else
      output_format=""
  fi

  ####
  # Generate lists of cases and groups that will run
  ####
  declare -a bats_files
  declare -a test_groups
  declare -a ignore_cases

  if [[ $# -eq 0 ]]; then
    # All test cases will be run
    for group in $(ls ${TEST_SUITE_ROOT} ); do
      test_groups+=( $group )
    done
  fi

  if [[ $# -eq 2 && $1 == 'groups' ]]; then
    if [[ $2 == '-l' ]]; then
      echo "The supported groups were: "
      ls -1 ./suites
      return 0
    else
      data=$2
      # Locate the bats files in the desired groups
      while read -d ',' group ; do
        test_groups+=( $group )
      done < <(echo ${data},)

      for group in ${test_groups[*]}; do
        for test in $(ls ${TEST_SUITE_ROOT}/${group}/*.bats); do
          bats_files+=( ${test} )
        done
      done
    fi
  fi

  if [[ $# -eq 2 && $1 == 'ignore_groups' ]]; then
   # Run all tests except specified groups
    data=$2
    tamp_data=`echo ${data//,/|}`
    echo "# Ignore the groups: $data"
    for group in $(ls ${TEST_SUITE_ROOT} | egrep -v "$tamp_data"); do
      test_groups+=( ${group} )
    done
  fi

  if [[ $# -eq 2 && $1 == 'ignore_cases' ]]; then
    data=$2
    # All groups will be run
    for group in $(ls ${TEST_SUITE_ROOT} ); do
      test_groups+=( $group )
    done

    # Find the full path of the cases to ignore
    while read -d ',' case ; do
      ignore_cases+=( $(ls ${TEST_SUITE_ROOT}/*/${case}.bats) )
    done < <(echo ${data},)
  fi

  if [[ $# -eq 2 && $1 == 'cases' ]]; then
    if [[ $2 == '-l' ]]; then
      echo "The supported cases were: "
      find ./suites -name *.bats | awk -F '/' '{print $4}' | awk -F . '{print $1}'
      return 0
    else
      data=$2
      # Find the full path of the specified cases
      while read -d ',' case ; do
        bats_files+=( $(ls ${TEST_SUITE_ROOT}/*/${case}.bats) )
      done < <(echo ${data},)

      # Find the groups for these cases
      for file in ${bats_files[*]}; do
        group=$(basename $( dirname ${file} ))
        if [[ ! " $test_groups[@] " =~ " ${group} " ]]; then
          test_groups+=( ${group} )
        fi
      done
    fi
  else
    if [[ $1 == 'ignore_groups' || $1 == 'ignore_cases' || $# -eq 0 ]]; then
      # Find all test cases in the desired test groups (minus the ignore_cases)
      for group in ${test_groups[*]}; do
        for test in $(ls ${TEST_SUITE_ROOT}/${group}/*.bats); do
         if [[ ! " ${ignore_cases[@]} " =~ " ${test} " ]]; then
           bats_files+=( ${test} )
         fi
       done
     done
   fi
  fi

  ####
  # Make sure test case prereqs are met
  ####
  if [[ "${PREINSTALL_PREREQS}" == "true" ]]; then
     # Include implicit capability requirements
     desired_capabilities=( ${IMPLICIT_CAPABILITIES[*]} )

     # Scan all bats files for explicit capability requirements
     for file in ${bats_files[*]}; do
       source <(grep "^CAPABILITIES=" ${file}) # TODO This may be unsafe, consider different method

       if [[ ! -z ${CAPABILITIES} ]]; then
         for capability in ${CAPABILITIES[*]}; do
           if [[ ! " ${desired_capabilities[@]} " =~ " ${capability} " ]]; then
             desired_capabilities+=( ${capability} )
           fi
         done
         unset CAPABILITIES
       fi
     done

     # Ensure that required capability requirements are met
     for capability in ${desired_capabilities[*]}; do
       # Each defined capability has a setup function
       setup_${capability}
     done
  fi

   ####
   # Run the tests
   ####
   if [[ ${#bats_files[@]} -lt 1 ]]; then
     echo "No test cases to run. Please check your input"
     return 1
   fi
   echo

   # Run all the pre-run setup
   # pre-run

   if [[ "${GROUP_RUNS}" == "true" ]]; then
     # Separate bats runs by groups
     for group in ${test_groups[*]}; do
       declare -a runcases
       # Get all the test cases in the curren group
       for case in ${bats_files[*]}; do
         if [[ $case =~ .*/${group}/.*\.bats ]]; then
           runcases+=( $case )
         fi
       done
       echo "# ==> $group"
       run bats ${output_format} ${runcases[*]}
       if [[ $? -ne 0 ]]; then
           EXIT_STATUS=1
       fi
       unset runcases
     done
   else
     # Run all cases in a single bats run
     bats ${output_format} ${bats_files[*]}
     if [[ $? -ne 0 ]]; then
         EXIT_STATUS=1
     fi
   fi
 }


if [[ $# -eq 0 ]]; then
  run_bats
else
  case $1 in
    '--groups'|-g)
       run_bats 'groups' $2
       ;;
    '--cases'|-c)
       run_bats 'cases' $2
        ;;
    '--ignore_groups'|-ng)
        run_bats 'ignore_groups' $2
        ;;
    '--ignore_cases'|-nc)
        run_bats 'ignore_cases' $2
        ;;
    '--help'|-h)
      help
      exit 0
       ;;
    *)
      help
      exit 1
       ;;
  esac
fi
