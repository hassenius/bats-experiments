#!/usr/bin/env bats
test="Fail Subsequent"
load ../../helpers
load ${sert_bats_workdir}/sequential-helpers.bash


@test "${test} | Simple 1 | Always fail" {

  if [[ ! 0 -eq 1 ]]; then
    skip_subsequent
  fi

  [[ 0 -eq 1 ]]
}

@test "${test} | Simple 1 | Fail this one" {

  v="foo"

  if [[  "${v}" == "bar" ]]; then
    skip_subsequent
  fi

  [ "${v}" == "bar" ]
}

@test "${test} | Simple 1 | Always pass2" {

  [[ 0 -eq 0 ]]
}

@test "${test} | Simple 1 | Always pass3" {

  [[ 0 -eq 0 ]]
}
