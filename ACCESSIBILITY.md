# Accessibility

Ledgerline is an iOS shared-expense ledger project in development.

## Current scope

The current [app screen](Ledgerline/Ledgerline/App/ContentView.swift) is a
SwiftUI placeholder. The ledger architecture described in the
[README](README.md) does not establish accessibility support for expense,
balance, or sharing workflows that are not yet exposed in the app UI.

## Validation and limitations

Full accessibility support has not been established by this statement.
As the app UI is implemented, verify meaningful control labels, spoken
amounts and currencies, non-colour balance and status cues, logical focus
order, and task completion with VoiceOver and Voice Control. Check the
largest text sizes, contrast, Reduce Motion, and error recovery for each
available workflow.

## Report an accessibility problem

[Open an issue](https://github.com/arieltyson/ledgerline/issues/new) describing
the affected screen, steps to reproduce, expected and actual behaviour,
and the app version or commit. Include your device, iOS version, and
relevant assistive technology or accessibility settings.
