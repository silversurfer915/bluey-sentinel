# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Bluey's primary user is its owner, who uses a Mac while studying or working and may use an iPhone or iPad as a companion controller.

## Product Purpose

Bluey is a personal AI companion for study and everyday tasks. It provides voice and text conversation, screen-aware assistance and computer control when invoked, focus sessions with optional Focus Sentinel monitoring, local study memory, and phone-based session controls.

## Positioning

Bluey combines an on-demand screen-aware Mac assistant with a study-focused session guardian and a paired phone controller. Ordinary conversation should remain lightweight; screen context and computer control are invoked only when a task needs them.

## Operating Context

Bluey runs primarily from the macOS menu bar. The owner opens its workspace when they need a larger view and may control focus sessions from a paired iPhone or iPad. Focus Sentinel can observe the active app or browser target while a focus session is active. Computer actions are governed by explicit access modes and an immediate Emergency Stop.

## Capabilities and Constraints

- The Mac app is a native SwiftUI/AppKit menu-bar companion. The iPhone/iPad app is a native controller for focus, quick actions, approvals, history, widgets, and Live Activities.
- The app must remain available from the menu bar and must not show a Bluey app icon or focus progress indicator in the Dock.
- Gemini 3.1 Flash Lite and Token Harbor are preferred fast/default providers; DeepSeek and custom OpenAI-compatible providers remain available.
- Screen context is invoked only when a request needs it. Computer control respects Off, Ask Every Time, and broader access modes, plus the latched Emergency Stop.
- Focus Sentinel, voice input, and focus session controls should remain usable from the shared Mac workspace and menu-bar entry points.
- The Sanctra integration exists in the codebase but is parked for this work. The UI redesign must not change its authentication, sync, or data behavior.
- Preserve existing bundle identifiers, pairing, focus/session state, provider routing, settings, and all working behavior during a visual redesign.

## Brand Commitments

The product name is Bluey. Keep the existing recognizable Bluey character identity and make it feel cute but restrained. The owner prefers calm, clean, relaxing visuals and explicitly rejects neon-heavy effects, a Bluey Dock icon, and a Bluey notch UI.

## Evidence on Hand

The repository contains the Mac menu-bar app, iPhone/iPad controller, Bluey visual assets, focus/session flows, provider settings, and local memory UI. Do not invent testimonials, performance claims, study outcomes, provider guarantees, or unverified external integration behavior.

## Product Principles

- Keep routine assistance quick and keep screen-aware actions explicit.
- Make focus state and computer-control safety immediately understandable.
- Keep Mac controls close to the menu bar and phone controls usable as a real controller.
- Preserve local privacy and make user-controlled memory understandable.
- Keep the interface calm and characterful without obscuring the user's work.

## Accessibility & Inclusion

Support keyboard navigation and visible focus on Mac, VoiceOver labels and logical reading order, system text sizing on phone and resizable Mac windows, Reduce Motion, and non-color-only status communication.
