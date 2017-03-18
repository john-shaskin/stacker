import logging

from .base import BaseAction
from .. import util
from ..exceptions import (
    MissingParameterException,
    StackDidNotChange,
    StackDoesNotExist,
)


from ..plan import Plan
from ..status import (
    NotSubmittedStatus,
    NotUpdatedStatus,
    DidNotChangeStatus,
    SubmittedStatus,
)


logger = logging.getLogger(__name__)


def should_update(stack):
    """Tests whether a stack should be submitted for updates to CF.

    Args:
        stack (:class:`stacker.stack.Stack`): The stack object to check.

    Returns:
        bool: If the stack should be updated, return True.

    """
    if stack.locked:
        if not stack.force:
            logger.debug("Stack %s locked and not in --force list. "
                         "Refusing to update.", stack.name)
            return False
        else:
            logger.debug("Stack %s locked, but is in --force "
                         "list.", stack.name)
    return True


def should_submit(stack):
    """Tests whether a stack should be submitted to CF for update/create

    Args:
        stack (:class:`stacker.stack.Stack`): The stack object to check.

    Returns:
        bool: If the stack should be submitted, return True.

    """
    if stack.enabled:
        return True

    logger.debug("Stack %s is not enabled.  Skipping.", stack.name)
    return False


def _resolve_parameters(parameters, blueprint):
    """Resolves CloudFormation Parameters for a given blueprint.

    Given a list of parameters, handles:
        - discard any parameters that the blueprint does not use
        - discard any empty values
        - convert booleans to strings suitable for CloudFormation

    Args:
        parameters (dict): A dictionary of parameters provided by the
            stack definition
        blueprint (:class:`stacker.blueprint.base.Blueprint`): A Blueprint
            object that is having the parameters applied to it.

    Returns:
        dict: The resolved parameters.

    """
    params = {}
    param_defs = blueprint.get_parameter_definitions()

    for key, value in parameters.items():
        if key not in param_defs:
            logger.debug("Blueprint %s does not use parameter %s.",
                         blueprint.name, key)
            continue
        if value is None:
            logger.debug("Got None value for parameter %s, not submitting it "
                         "to cloudformation, default value should be used.",
                         key)
            continue
        if isinstance(value, bool):
            logger.debug("Converting parameter %s boolean \"%s\" to string.",
                         key, value)
            value = str(value).lower()
        params[key] = value
    return params


class Action(BaseAction):

    """Responsible for building & coordinating CloudFormation stacks.

    Generates the build plan based on stack dependencies (these dependencies
    are determined automatically based on output lookups from other stacks).

    The plan can then either be printed out as an outline or executed. If
    executed, each stack will get launched in order which entails:

        - Pushing the generated CloudFormation template to S3 if it has changed
        - Submitting either a build or update of the given stack to the
            :class:`stacker.provider.base.Provider`.

    """

    def build_parameters(self, stack):
        """Builds the CloudFormation Parameters for our stack.

        Args:
            stack (:class:`stacker.stack.Stack`): A stacker stack

        Returns:
            dict: The parameters for the given stack

        """
        resolved = _resolve_parameters(stack.parameter_values, stack.blueprint)
        required_parameters = stack.required_parameter_definitions.keys()
        parameters = self._handle_missing_parameters(
            resolved, required_parameters, stack.fqn)
        return [
            {'ParameterKey': p[0],
             'ParameterValue': str(p[1])} for p in parameters
        ]

    def _build_stack_tags(self, stack):
        """Builds a common set of tags to attach to a stack"""
        return [
            {'Key': t[0], 'Value': t[1]} for t in self.context.tags.items()]

    def _launch_stack(self, stack, **kwargs):
        """Handles the creating or updating of a stack in CloudFormation.

        Also makes sure that we don't try to create or update a stack while
        it is already updating or creating.

        """
        if not should_submit(stack):
            return NotSubmittedStatus()

        logger.debug("Resolving stack %s", stack.fqn)
        stack.resolve(self.context, self.provider)

        logger.debug("Launching stack %s now.", stack.fqn)
        template_url = self.s3_stack_push(stack.blueprint)
        tags = self._build_stack_tags(stack)
        parameters = self.build_parameters(stack)

        # Try to update, if the update fails try to create a new stack
        # This is a speed improvement because the update case happens
        # much more often than the create case.

        if not should_update(stack):
            return NotUpdatedStatus()

        try:
            self.provider.update_stack(stack.fqn, template_url,
                                       parameters, tags)
            logger.debug("Updating existing stack: %s", stack.fqn)
            return SubmittedStatus("UPDATING_STACK")
        except StackDidNotChange:
            return DidNotChangeStatus()
        except StackDoesNotExist:
            logger.debug("Creating new stack: %s", stack.fqn)
            self.provider.create_stack(stack.fqn, template_url, parameters,
                                       tags)
            return SubmittedStatus("CREATE_STACK")

    def _generate_plan(self, tail=False):

        plan = Plan(description="Create/Update stacks",
                    logger_type=self.context.logger_type,
                    tail=tail,
                    poll_func=self.provider.poll_events)
        stacks = self.context.get_stacks_dict()
        dependencies = self._get_dependencies()
        for stack_name in self.get_stack_execution_order(dependencies):
            plan.add(
                stacks[stack_name],
                run_func=self._launch_stack,
                requires=dependencies.get(stack_name),
            )
        return plan

    def _get_dependencies(self):
        dependencies = {}
        for stack in self.context.get_stacks():
            dependencies[stack.fqn] = stack.requires
        return dependencies

    def pre_run(self, outline=False, dump=False, *args, **kwargs):
        """Any steps that need to be taken prior to running the action."""
        pre_build = self.context.config.get("pre_build")
        should_run_hooks = (
            not outline and
            not dump and
            pre_build
        )
        if should_run_hooks:
            util.handle_hooks(
                stage="pre_build",
                hooks=pre_build,
                provider=self.provider,
                context=self.context)

    def run(self, outline=False, tail=False, dump=False, *args, **kwargs):
        """Kicks off the build/update of the stacks in the stack_definitions.

        This is the main entry point for the Builder.

        """
        plan = self._generate_plan(tail=tail)
        if not outline and not dump:
            plan.outline(logging.DEBUG)
            logger.debug("Launching stacks: %s", ", ".join(plan.keys()))
            plan.execute()
        else:
            if outline:
                plan.outline()
            if dump:
                plan.dump(directory=dump, context=self.context)

    def cleanup(self):
        """Cleans up any resources that do not need to exist after stacker
        has finished building all the stacks.

        This is specifically used when deleting the sqs queues used for
        polling events.

        """
        logger.debug('Cleaning up sqs queues')
        self.provider.cleanup()

    def post_run(self, outline=False, dump=False, *args, **kwargs):
        """Any steps that need to be taken after running the action."""
        post_build = self.context.config.get("post_build")
        if not outline and not dump and post_build:
            util.handle_hooks(
                stage="post_build",
                hooks=post_build,
                provider=self.provider,
                context=self.context)

    def _handle_missing_parameters(self, params, required_params,
                                   existing_stack_name=None):
        """Handles any missing parameters.

        If an existing_stack is provided, look up missing parameters there.

        Args:
            params (dict): key/value dictionary of stack definition parameters
            required_params (list): A list of required parameter names.
            existing_stack_name (string): The name of the current stack

        Returns:
            list of tuples: The final list of key/value pairs returned as a
                list of tuples.

        Raises:
            MissingParameterException: Raised if a required parameter is
                still missing.
        """
        missing_params = list(set(required_params) - set(params.keys()))
        if missing_params:

            existing_stack = None

            logger.debug(
                "Handling missing params for %s.", existing_stack_name)

            try:
                existing_stack = self.provider.get_stack(existing_stack_name)
            except StackDoesNotExist:
                pass

            if existing_stack and 'Parameters' in existing_stack:
                stack_params = {p['ParameterKey']: p['ParameterValue'] for p in
                                existing_stack['Parameters']}
                for p in missing_params:
                    if p in stack_params:

                        value = stack_params[p]
                        logger.debug("Parameter %s from existing stack: %s",
                                     p, value)
                        params[p] = value
            final_missing = list(set(required_params) - set(params.keys()))
            if final_missing:
                raise MissingParameterException(final_missing)

        return params.items()
