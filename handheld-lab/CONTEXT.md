# Handheld DevTools

Handheld DevTools is the system-level observation and control boundary used to
diagnose handheld Linux targets and automate software running on them.

## Language

**Target**:
A real handheld, virtual handheld, or target container being observed and controlled.
_Avoid_: Device, box, test machine

**Controller**:
The host-side interface used by a human, test runner, or AI to operate a Target.
_Avoid_: Client, test script

**Probe**:
The small target-side executor that discovers and invokes Target capabilities.
_Avoid_: Agent, APP helper, APP Manager service

**Dev Toolbox**:
The optional heavy debugging environment used when a Target needs compilers,
tracers, debuggers, or symbol tools.
_Avoid_: Probe, DevTools

**Capability**:
An operation a Target can actually perform through one selected Provider.
_Avoid_: Feature flag, assumed support

**Provider**:
A target-specific implementation of a Capability, selected by runtime discovery.
_Avoid_: Platform branch, special case

**Observation**:
A bounded runtime fact collected from a Target without changing the program under test.
_Avoid_: Dump, probe result

**Evidence Bundle**:
The timestamped commands, observations, logs, images, and outcomes from one diagnostic run.
_Avoid_: Debug log, report

**Scenario**:
An ordered, machine-readable sequence of actions and expectations applied to a Target.
_Avoid_: APP test, macro

**Autonomous Debugging**:
An AI-driven loop that forms a hypothesis, performs an action, collects observations, and
uses the resulting evidence to choose the next action.
_Avoid_: Custom debugging, automatic clicking

**Platform Profile**:
Optional provider hints for one family of Targets; it must not contain product business logic.
_Avoid_: Device-specific implementation
