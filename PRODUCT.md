# Keep Awake

## Register

product

## Platform

Native macOS, Apple silicon. AppKit menu bar integration, NSMenu controls, and standard macOS alerts.

## Purpose

Jakub wants an installable keep-awake utility with a menu bar icon and options similar to Amphetamine. The App Store currently cannot complete app installations on his company Mac. The existing command-line prototype is the starting point.

## Scope

Timed and indefinite sessions, ordinary idle prevention, closed-lid sessions, battery and charger options, a visible Stop control, and optional launch at login. The source project belongs in `/Users/jmatyka/Projects/KeepAwake`.

## Implementation choices

Use the real macOS menu renderer, system typography, system selection color, checkmarks, and compact submenus. The user supplied Wi-Fi and Mole menus as visual references and asked to replace the custom orange control panel. The application icon uses an orange cup; the menu bar icon is a monochrome system symbol. Administrator approval belongs at closed-lid session start. The main app stays unprivileged.

## Accessibility

Use standard keyboard navigation, descriptive accessibility labels, text alongside state indicators, and the system reduced-motion preference.
