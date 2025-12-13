# User Stories: GhostType

## 1. Core Dictation & Performance
*   **As a fast talker,** I want my speech to be transcribed with a "Time-to-First-Token" of under 200ms, so that I don't lose my train of thought waiting for the computer to catch up.
*   **As a user who pauses to think,** I want the system to smart-detect when I've truly finished a sentence versus just pausing for a word (using Voice Activity Detection), so it doesn't cut me off prematurely.
*   **As a professional,** I want my dictated text to be grammatically corrected (e.g., "heres the code" -> "Here's the code") automatically, so I don't have to manually edit the output.
*   **As a battery-conscious user,** I want the app to use the Apple Neural Engine for processing, so that it doesn't drain my MacBook's battery or cause fans to spin up.

## 2. User Interface & Feedback
*   **As a writer,** I want to see "provisional" text (greyed out) appear immediately as I speak, so I know the system is listening, even before the final accurate text is ready.
*   **As a user working in full-screen apps,** I want a minimal floating indicator ("GhostPill") near my text cursor that pulses with my voice volume, so I have visual confirmation that the microphone is active without looking away from my work.
*   **As a user who dictates commands,** I want the finalized text to turn black and "lock in" smoothly, providing a seamless transition from thought to text.

## 3. System Integration & Workflow
*   **As a developer coding in VS Code,** I want the dictation overlay to appear right next to my cursor, regardless of which application I am using.
*   **As a multitasker,** I want to toggle dictation on and off with a single global hotkey, so I can switch between typing and speaking instantly.
*   **As a Slack user,** I want the transcribed text to be inserted directly into the message field as if I typed it, without needing to copy-paste from a separate window.

## 4. Privacy & Security
*   **As a privacy-conscious user,** I want all my voice data to be processed locally on my device, so I know my private conversations and drafts are never sent to a cloud server.
*   **As a security-minded user,** I want to explicitly grant microphone and accessibility permissions, so I remain in control of what the app can access.

## 5. Onboarding & Setup
*   **As a new user,** I want a clear onboarding wizard that verifies my microphone is working and permissions are granted, so I don't face silent failures when I first try to dictate.
*   **As a user with a slow internet connection,** I want the app to work with a smaller, faster model ("Moonshine Tiny") out of the box, with the option to download "Pro" models later.
