#!/usr/bin/env bats

load test_helper

@test "stacker build - no config" {
  stacker build
  assert ! "$status" -eq 0
  assert_has_line "stacker build: error: too few arguments"
}

@test "stacker build - empty config" {
  stacker build <(echo "")
  assert ! "$status" -eq 0
  assert_has_line 'Should have more than one element'
}

@test "stacker build - config with no stacks" {
  stacker build - <<EOF
namespace: ${STACKER_NAMESPACE}
EOF
  assert ! "$status" -eq 0
  assert_has_line 'Should have more than one element'
}

@test "stacker build - config with no namespace" {
  stacker build - <<EOF
stacker_bucket: stacker-${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
EOF
  assert ! "$status" -eq 0
  assert_has_line "This field is required"
}

@test "stacker build - missing environment key" {
  environment() {
    cat <<EOF
vpc_private_subnets: 10.128.8.0/22,10.128.12.0/22,10.128.16.0/22,10.128.20.0/22
EOF
  }

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
    variables:
      PublicSubnets: \${vpc_public_subnets}
      PrivateSubnets: \${vpc_private_subnets
EOF
  }

  # Create the new stacks.
  stacker build <(environment) <(config)
  assert ! "$status" -eq 0
  assert_has_line "stacker.exceptions.MissingEnvironment: Environment missing key vpc_public_subnets."
}

@test "stacker build - duplicate stacks" {
  stacker build - <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
EOF
  assert ! "$status" -eq 0
  assert_has_line "Duplicate stack vpc found"
}

@test "stacker build - missing variable" {
  needs_aws

  stacker build - <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
EOF
  assert ! "$status" -eq 0
  assert_has_line "stacker.exceptions.MissingVariable: Variable \"PublicSubnets\" in blueprint \"vpc\" is missing"
}

@test "stacker build - simple build" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
    variables:
      PublicSubnets: 10.128.0.0/24,10.128.1.0/24,10.128.2.0/24,10.128.3.0/24
      PrivateSubnets: 10.128.8.0/22,10.128.12.0/22,10.128.16.0/22,10.128.20.0/22
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0
  assert_has_line "Using default AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-vpc: pending"
  assert_has_line "${STACKER_NAMESPACE}-vpc: submitted (creating new stack)"
  assert_has_line "${STACKER_NAMESPACE}-vpc: complete (creating new stack)"

  # Perform a noop update to the stacks, in interactive mode.
  stacker build -i <(config)
  assert "$status" -eq 0
  assert_has_line "Using interactive AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-vpc: pending"
  assert_has_line "${STACKER_NAMESPACE}-vpc: skipped (nochange)"

  # Cleanup
  stacker destroy --force <(config)
  assert "$status" -eq 0
  assert_has_line "${STACKER_NAMESPACE}-vpc: pending"
  assert_has_line "${STACKER_NAMESPACE}-vpc: submitted (submitted for destruction)"
  assert_has_line "${STACKER_NAMESPACE}-vpc: complete (stack destroyed)"
}

@test "stacker build - simple build with output lookups" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
  - name: bastion
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
    variables:
      StringVariable: \${output vpc::DummyId}
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0
  assert_has_line "Using default AWS provider mode"

  for stack in vpc bastion; do
    assert_has_line -E "${STACKER_NAMESPACE}-${stack}:\s.*pending"
    assert_has_line -E "${STACKER_NAMESPACE}-${stack}:\s.*submitted \(creating new stack\)"
    assert_has_line -E "${STACKER_NAMESPACE}-${stack}:\s.*complete \(creating new stack\)"
  done
}

@test "stacker build - simple build with environment" {
  needs_aws

  environment() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
vpc_public_subnets: 10.128.0.0/24,10.128.1.0/24,10.128.2.0/24,10.128.3.0/24
vpc_private_subnets: 10.128.8.0/22,10.128.12.0/22,10.128.16.0/22,10.128.20.0/22
EOF
  }

  config() {
    cat <<EOF
namespace: \${namespace}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
    variables:
      PublicSubnets: \${vpc_public_subnets}
      PrivateSubnets: \${vpc_private_subnets
EOF
  }

  teardown() {
    stacker destroy --force <(environment) <(config)
  }

  # Create the new stacks.
  stacker build <(environment) <(config)
  assert "$status" -eq 0
}

@test "stacker build - no namespace" {
  needs_aws

  config() {
    cat <<EOF
namespace: ""
stacks:
  - name: ${STACKER_NAMESPACE}-vpc
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0
}

@test "stacker build - overriden environment key with -e" {
  needs_aws

  environment() {
    cat <<EOF
namespace: stacker
EOF
  }

  config() {
    cat <<EOF
namespace: \${namespace}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.VPC
    variables:
      PublicSubnets: 10.128.0.0/24,10.128.1.0/24,10.128.2.0/24,10.128.3.0/24
      PrivateSubnets: 10.128.8.0/22,10.128.12.0/22,10.128.16.0/22,10.128.20.0/22
EOF
  }

  teardown() {
    stacker destroy -e namespace=$STACKER_NAMESPACE --force <(environment) <(config)
  }

  # Create the new stacks.
  stacker build -e namespace=$STACKER_NAMESPACE <(environment) <(config)
  assert "$status" -eq 0
  assert_has_line "${STACKER_NAMESPACE}-vpc: submitted (creating new stack)"
}

@test "stacker build - dump" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
  - name: bastion
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
    variables:
      StringVariable: \${output vpc::DummyId}
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0

  stacker build -d "$TMP" <(config)
  assert "$status" -eq 0
}

@test "stacker diff - simple diff with output lookups" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: vpc
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
  - name: bastion
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
    variables:
      StringVariable: \${output vpc::DummyId}
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0

  stacker diff <(config)
  assert "$status" -eq 0
}

@test "stacker build - replacements-only test with additional resource, no keyerror" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: add-resource-test-with-replacements-only
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy

EOF
  }

config2() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: add-resource-test-with-replacements-only
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy2

EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # Create the new stacks.
  stacker build <(config)
  assert "$status" -eq 0
  assert_has_line "Using default AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: pending"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: submitted (creating new stack)"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: complete (creating new stack)"

  # Perform a additional resouce addition in replacements-only mode, should not crash.  This is testing issue #463.
  stacker build -i --replacements-only <(config2)
  assert "$status" -eq 0
  assert_has_line "Using interactive AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: pending"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: complete (updating existing stack)"

  # Cleanup
  stacker destroy --force <(config2)
  assert "$status" -eq 0
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: pending"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: submitted (submitted for destruction)"
  assert_has_line "${STACKER_NAMESPACE}-add-resource-test-with-replacements-only: complete (stack destroyed)"
}

@test "stacker build - default mode, without & with protected stack" {
  needs_aws

  config() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: mystack
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy
    protected: ${PROTECTED}

EOF
  }

  config2() {
    cat <<EOF
namespace: ${STACKER_NAMESPACE}
stacks:
  - name: mystack
    class_path: stacker.tests.fixtures.mock_blueprints.Dummy2
  
EOF
  }

  teardown() {
    stacker destroy --force <(config)
  }

  # First create the stack
  PROTECTED="false" stacker build --interactive <(config)
  assert "$status" -eq 0
  assert_has_line "Using interactive AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-mystack: pending"
  assert_has_line "${STACKER_NAMESPACE}-mystack: submitted (creating new stack)"
  assert_has_line "${STACKER_NAMESPACE}-mystack: complete (creating new stack)"

  # Perform a additional resouce addition in interactive mode, non-protected stack
  echo "y" | stacker build --interactive <(config2)
  assert "$status" -eq 0
  assert_has_line "Using interactive AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-mystack: pending"
  assert_has_line "${STACKER_NAMESPACE}-mystack: submitted (updating existing stack)"
  assert_has_line "${STACKER_NAMESPACE}-mystack: complete (updating existing stack)"

  # Perform another update, this time without interactive, but with a protected stack
  echo "y" | PROTECTED="true" stacker build <(config)
  assert "$status" -eq 0
  assert_has_line "Using default AWS provider mode"
  assert_has_line "${STACKER_NAMESPACE}-mystack: pending"
  assert_has_line "${STACKER_NAMESPACE}-mystack: submitted (updating existing stack)"
  assert_has_line "${STACKER_NAMESPACE}-mystack: complete (updating existing stack)"

  # Cleanup
  stacker destroy --force <(config2)
  assert "$status" -eq 0
  assert_has_line "${STACKER_NAMESPACE}-mystack: pending"
  assert_has_line "${STACKER_NAMESPACE}-mystack: submitted (submitted for destruction)"
  assert_has_line "${STACKER_NAMESPACE}-mystack: complete (stack destroyed)"
}
