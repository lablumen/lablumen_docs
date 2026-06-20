# LabLumen Frontend Vision
**Head of Product Design, UX & Frontend Architecture**
*Prepared: June 19, 2026 | Status: Pre-Implementation Design Spec*

---

> This document is the single source of truth for the LabLumen frontend redesign. It defines what we're building, why, and precisely how each piece should look, feel, and behave. No code is written here — but every decision that shapes the code is made here. Engineers should be able to implement directly from this spec.

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Information Architecture](#2-information-architecture)
3. [Navigation Structure](#3-navigation-structure)
4. [User Flows](#4-user-flows)
5. [Screen-by-Screen Wireframes](#5-screen-by-screen-wireframes)
6. [Component Hierarchy](#6-component-hierarchy)
7. [Design System](#7-design-system)
8. [Layout Specifications](#8-layout-specifications)
9. [Motion Guidelines](#9-motion-guidelines)
10. [Mobile Strategy](#10-mobile-strategy)
11. [Desktop Strategy](#11-desktop-strategy)
12. [Implementation Roadmap](#12-implementation-roadmap)

---

## 1. Design Philosophy

### The Core Problem

LabLumen has excellent bones — a solid engineering foundation, a compelling AI-first differentiator, and a real product solving a real problem. But the frontend communicates none of that.

Today, LabLumen feels like:

- A hospital admin portal from 2018
- Three CRUD screens dressed in a dark-teal color scheme
- A prototype that someone forgot to finish

The AI report understanding feature — the product's genuine superpower — is buried three clicks deep inside a modal that breaks completely on mobile.

This redesign does not change the product. It reveals it.

### The Target Experience

LabLumen should feel like **a private clinic experience delivered through software built in 2026.**

The patient who opens a report at midnight, anxious about their numbers, should feel:
- Calm, not overwhelmed
- Informed, not confused
- Supported, not alone

The lab nurse who uploads 40 reports before 2pm should feel:
- Fast, not frustrated
- In control, not lost
- Clear on what's done and what isn't

### Reference Products — What We're Taking From Each

| Reference | What We Borrow |
|-----------|---------------|
| **Linear** | Persistent sidebar navigation. Keyboard-first thinking. Dense information done right. Status everywhere. |
| **Stripe** | Trust through typography. Data-rich but never overwhelming. Status badges, event timelines, clear hierarchy. |
| **Notion** | The reading experience as a first-class surface. Documents that feel like documents, not forms. |
| **Raycast** | Speed as a value. Zero friction between intent and action. Command-palette thinking. |
| **Apple Health** | Compassionate data. Health information presented humanely, not clinically. Color used with restraint and purpose. |
| **Calendly** | The booking wizard as a premium multi-step experience. Every step feels complete and intentional. |
| **Arc Browser** | Spatial thinking. Layered surfaces. The app teaches itself through use, not tutorials. |

### The Visual Mandate

> "Premium, trustworthy, AI-first healthcare software. Not a dashboard. Not a form. An experience."

**Use:**
- Large, editorial typography for key values and headers
- Generous whitespace — breathing room signals quality
- Layered surfaces — depth creates hierarchy without borders
- Purposeful color — teal is the brand, not decoration
- Glassmorphism only where it creates genuine depth (not everywhere)
- Skeleton loading states shaped exactly like the content they precede
- Micro-interactions that confirm every user action

**Never use:**
- Bootstrap-style stacked form fields as primary UI
- Dense tables as the first thing a user sees
- Bento cards as a one-size-fits-all layout unit
- Overuse of borders (borders are a last resort — use spacing and elevation)
- Generic marketing language ("powerful", "seamless", "robust")

---

## 2. Information Architecture

### Sitemap

```
[Public]
├── /                         → Landing page (product homepage)
├── /login                    → Premium split-panel authentication
└── /forgot-password          → Password reset flow

[Patient App — /app]
├── /app                      → Patient workspace (home)
├── /app/book                 → Multi-step booking wizard
│   └── (step state managed via URL params: ?step=1-5)
├── /app/appointments         → Appointment list (upcoming + history)
├── /app/reports              → Report list with filters and search
│   └── /app/reports/:id      → Report workspace (PDF + AI + Chat)
├── /app/family               → Family profile management
└── /app/settings             → Account settings, password change

[Staff App — /staff]
├── /staff                    → Operations queue (default: today)
└── /staff/reports            → Report management view

[Future — not in this redesign]
├── /admin/catalog            → Lab test management
├── /admin/users              → Staff user management
└── /admin/settings           → Clinic settings
```

### Route Access Matrix (Updated)

| Route | Anonymous | Patient | Staff |
|-------|-----------|---------|-------|
| `/` | ✓ (landing) | → /app | → /staff |
| `/login` | ✓ | → /app | → /staff |
| `/forgot-password` | ✓ | ✓ | ✓ |
| `/app/*` | → /login | ✓ | → /staff |
| `/staff/*` | → /login | → /app | ✓ |

### Structural Principles

1. **One purpose per page.** Booking and reports do not share a screen. Each page has a single primary action or view.

2. **No critical features behind modals.** The report workspace is a page, not a modal. Booking is a wizard page, not an inline form. Modals are used only for confirmations and quick destructive actions.

3. **Every role has a home.** Patient lands on `/app` (workspace). Staff lands on `/staff` (today's queue). Neither is confused about where they are.

4. **Navigation reflects mental models.** A patient thinks: "Home → Book → Appointments → Reports → Family." A staff member thinks: "Queue → Reports." Navigation matches this exactly.

5. **AI is a first-class surface.** The AI panel is not a tab inside a modal. It is the right half of the flagship experience. It has suggested questions. It remembers context.

---

## 3. Navigation Structure

### Patient Sidebar (Desktop — 240px, fixed)

```
┌─────────────────────────┐
│  ⬡ LabLumen            │  ← Logo + wordmark, links to /app
│                         │
│  ─── Main ──────────── │
│  ⊞  Home               │  /app
│  ＋  Book a Test        │  /app/book
│  📅  Appointments       │  /app/appointments
│  📄  Reports            │  /app/reports  [badge: "2 new"]
│  ✦  AI Assistant       │  /app/reports (last viewed report)
│                         │
│  ─── Account ─────────  │
│  👥  Family             │  /app/family
│  ⚙   Settings          │  /app/settings
│                         │
│  ─────────────────────  │
│  ○ Sarah Mitchell       │  User avatar + name
│    sarah@example.com    │
│    [Sign out]           │
└─────────────────────────┘
```

**Active state:** The active link has a teal left border (3px), teal text, teal-50 background fill. Not a pill badge — a full-width active row that breathes.

**Badge behavior:** The "Reports" link shows a badge count for reports in "Processing" state, turning from warning amber to success teal when all resolve.

---

### Staff Sidebar (Desktop — 240px, fixed)

```
┌─────────────────────────┐
│  ⬡ LabLumen            │
│                         │
│  ─── Operations ──────  │
│  ⊞  Queue              │  /staff  [badge: "4 pending"]
│  📄  Reports            │  /staff/reports
│                         │
│  ─── Account ─────────  │
│  ⚙   Settings          │
│                         │
│  ─────────────────────  │
│  ○ Nurse Kim            │
│    kim@lab.com          │
│    [Sign out]           │
└─────────────────────────┘
```

**Top header (staff):** A slim 48px bar spanning the full content area. Contains the current date prominently (since date context is critical for operations) and a date navigator (< Today >) for viewing other days.

---

### Patient Mobile Navigation (Bottom Tab Bar)

```
┌─────────────────────────────────────────────────┐
│  ⊞      ＋      📄      ✦       👤              │
│ Home  Book  Reports  AI     Me                  │
└─────────────────────────────────────────────────┘
```

Five tabs. Active tab: teal icon + teal label. Inactive: slate icon + slate label. No border above — a subtle shadow separates from content.

---

### Staff Mobile Navigation (Bottom Tab Bar)

```
┌──────────────────────────────────┐
│  ⊞         📄          ⚙        │
│ Queue   Reports    Settings      │
└──────────────────────────────────┘
```

---

## 4. User Flows

### Flow A: First-Time Patient (New Account → First Booking)

```
Receive invite email or staff creates account
        │
        ▼
/login  ─  premium split-panel
        │  enters credentials
        ▼
/app  ─  welcome state ("Get started" banner)
        │  "Start by adding a patient profile to book your first test →"
        ▼
/app/family  ─  "Add profile" sheet slides in from right
        │  fills name, DOB, gender, relationship
        │  saves → profile appears
        ▼
/app/book  ─  Step 1: profile pre-selected
        │  Steps 2–5: test → date → time → confirm
        ▼
/app/book?step=success  ─  confirmation screen
        │
        ▼
Navigates to /app  ─  appointment widget now shows "Tomorrow, 10:30 AM"
```

**Key UX improvements over current:**
- Profile creation is a dedicated sheet, not an inline accordion
- Booking is never triggered accidentally — 5 deliberate steps
- Confirmation is a full-page success state, not inline green text

---

### Flow B: Patient Returns, Views Report

```
/app  ─  "Latest report: CBC — Ready"  [View →]
        │
        ▼
/app/reports/:id  ─  report workspace loads
        │  Left: PDF iframe renders
        │  Right: AI summary visible immediately
        │  "Suggested questions" appear below summary
        ▼
Patient reads summary
        │  clicks suggested question or types own
        ▼
Chat panel activates in same right panel
        │  AI responds with markdown
        │  conversation continues
        ▼
Patient downloads PDF (button in report header)
        │
        ▼
← Back to Reports (breadcrumb or back button)
```

**Key UX improvements over current:**
- Deep-linkable URL — patients can bookmark or share reports
- Summary and chat in the same panel, not hidden behind a FAB
- Suggested questions surface the AI capability immediately
- Escape key closes nothing — this is a page, not a modal

---

### Flow C: Staff Daily Ops (Upload Reports)

```
/staff  ─  defaults to today's queue
        │  date header shows "Thursday, June 19"
        │  metrics: 12 scheduled · 8 done · 4 pending
        ▼
Queue table shows today's rows sorted: Pending Upload first
        │
Staff sees "John Doe — CBC — 09:00 — Pending Upload"
        │
        ├── Option A: Click row → upload zone expands inline
        │   Drag PDF from desktop → drop
        │   Progress bar fills
        │   Row updates to "AI Processing..." (amber)
        │   ~30 seconds → "Ready" (teal)
        │
        └── Option B: Clicks "Upload PDF" button
            File picker opens (fallback)
            Same progress + status behavior
```

**Key UX improvements over current:**
- Default date is today (not all-time)
- Pending uploads sort to top
- Drag-and-drop (not just click)
- Progress bar on upload
- AI processing status visible inline in the row — staff knows what's happening

---

### Flow D: Patient Family Booking (Booking for Child/Dependent)

```
/app/book  →  Step 1: "Who is this for?"
        │
        │  [Sarah — Self ✓]  [Tom — Son]  [+ Add person]
        │
        Selects Tom
        │
        ▼
Step 2: tests (same as standard flow)
        │
        ▼
Review shows: "Patient: Tom Mitchell (Son)"
        │
        ▼
Confirmed — booking is for Tom
```

**Key UX improvements over current:**
- Family selection is the FIRST step of booking, not buried in a form
- Clean card grid — each family member is a selectable card with name + relationship
- "Add person" opens a side sheet (same pattern as /app/family)

---

### Flow E: Password Reset

```
/login  →  "Forgot password?" link
        │
        ▼
/forgot-password  ─  single centered card
        │  "Enter your email address"
        │  [you@example.com ─────────────]
        │  [Send reset link]
        ▼
Success state: "Check your email — we've sent reset instructions to you@example.com"
        │
        ▼
Email → Cognito reset link → New password form
        │
        ▼
/login  with success toast "Password updated — please sign in"
```

---

## 5. Screen-by-Screen Wireframes

### 5.1 Landing Page (`/`)

**Purpose:** Communicate the value of LabLumen to anyone who visits — patients and labs alike. Convert anonymous visitors into account holders (or waitlist signups).

**Above the fold — Hero:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⬡ LabLumen                              [Login]  [Get started →]   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Your lab results,                  ┌────────────────────────────┐  │
│   finally explained.                 │  ✦ AI Report Summary       │  │
│                                      │  ─────────────────────────  │  │
│   AI-powered report understanding    │  Your CBC results are all  │  │
│   that makes your health data        │  within normal range.      │  │
│   human — without waiting            │                            │  │
│   for a callback.                    │  Hemoglobin  14.2 g/dL ✓  │  │
│                                      │  WBC         7.2 ×10³ ✓   │  │
│   [Book a test →]                    │  Platelets   245 ×10³ ✓   │  │
│   [Learn how it works ↓]             │                            │  │
│                                      │  "Is my hemoglobin in a   │  │
│                                      │   good range for my age?" │  │
│                                      │  [Ask →]                  │  │
│                                      └────────────────────────────┘  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The right side shows a live-styled mockup of the AI summary panel — the product sells itself visually.

**Section 2 — How It Works (3 steps, horizontal):**

```
  1. Book online          2. Walk in, walk out       3. Results with AI
  ─────────────────       ────────────────────       ──────────────────
  Choose your tests,      No waiting rooms.           Receive your PDF
  pick a date and         No paperwork.               with a plain-English
  time, confirm.          Just your appointment.      AI explanation.
  [visual: calendar]      [visual: clinic door]       [visual: phone+report]
```

**Section 3 — Features (for patients):**

```
  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
  │  AI that         │  │  Ask anything.   │  │  Book for your   │  │  Results in      │
  │  understands     │  │  "What does my   │  │  whole family.   │  │  hours, not      │
  │  your results.   │  │  LDL mean?"      │  │  Add dependents  │  │  days.           │
  └──────────────────┘  └──────────────────┘  └──────────────────┘  └──────────────────┘
```

**Section 4 — For Labs:**

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │  Built for clinical labs that want to modernize their workflow.    │
 │                                                                    │
 │  Digital booking       Staff ops dashboard      Automated          │
 │  replaces phone calls  with PDF upload queue    AI processing      │
 └─────────────────────────────────────────────────────────────────────┘
```

**Section 5 — Trust Indicators:**

```
  HIPAA-Ready  ·  End-to-End Encryption  ·  AI-Powered  ·  Trusted by Independent Labs
```

**Final CTA:**

```
  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  Ready to understand your health?                       │
  │                                                         │
  │  [Book a test →]          [I'm a lab — get in touch]   │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

### 5.2 Login (`/login`)

**Layout:** Split panel. Left 55% brand + product preview. Right 45% auth form. On mobile: stacked, right panel visible first (auth form up top), brand panel collapses below it.

**Left Panel — Brand Story:**

```
┌──────────────────────────────────────┐
│                                      │
│  ⬡ LabLumen                         │
│                                      │
│  "Understand your health.            │
│   Finally."                          │
│                                      │
│  ┌────────────────────────────────┐  │
│  │  ✦ AI Summary — CBC           │  │
│  │  ───────────────────────────  │  │
│  │  All values within normal     │  │
│  │  range. No immediate          │  │
│  │  attention required.          │  │
│  │                               │  │
│  │  "What does my WBC count      │  │
│  │   mean for my immunity?"      │  │
│  │   ↳ AI: Your WBC count of... │  │
│  └────────────────────────────────┘  │
│                                      │
│  ✓  AI-powered report understanding │
│  ✓  Book tests online               │
│  ✓  Secure & private                │
│  ✓  Results explained simply        │
│                                      │
└──────────────────────────────────────┘
```

Background: Deep teal-to-slate gradient (`#0F766E` → `#0F172A`). White text. The product preview card uses glassmorphism on the dark background — this is one of the appropriate uses of glass.

**Right Panel — Auth Form:**

```
┌──────────────────────────────────────┐
│                                      │
│  Welcome back.                       │
│  Sign in to continue.                │
│                                      │
│  Email address                       │
│  ┌──────────────────────────────┐    │
│  │  you@example.com             │    │
│  └──────────────────────────────┘    │
│                                      │
│  Password                  [Forgot?] │
│  ┌──────────────────────── [👁] ┐    │
│  │  ••••••••                    │    │
│  └──────────────────────────────┘    │
│                                      │
│  [Sign in →]                         │
│                                      │
│  ───────────── or ─────────────      │
│                                      │
│  Don't have an account?              │
│  [Request access →]                  │
│                                      │
└──────────────────────────────────────┘
```

- "Forgot?" is a right-aligned link beside the password label
- The eye icon toggles password visibility
- Error state: red border on the field with the problem + error message below the field
- Submit shows a spinner inside the button (not text change only)
- Background: pure white, no surface tint

---

### 5.3 Patient Home (`/app`)

**Purpose:** Answer "What should I care about today?" — not a traditional dashboard.

**Layout:** Sidebar (240px) + content area.

```
┌─ Sidebar ─┬────────────────────────────────────────────────────────┐
│           │  Good morning, Sarah.                                  │
│           │  Thursday, June 19                                     │
│           │                                                        │
│           │  ─────────────────────────────────────────────────    │
│           │                                                        │
│           │  ┌── Upcoming ─────────────────────────────────────┐  │
│           │  │  CBC + Lipid Panel                              │  │
│           │  │  Tomorrow, Friday June 20 · 10:30 AM            │  │
│           │  │  Sarah Mitchell (Self)                          │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ┌── Latest Report ──────────────┐                    │
│           │  │  Complete Blood Count (CBC)   │                    │
│           │  │  Jun 18 · Sarah Mitchell      │                    │
│           │  │  ● Ready                      │                    │
│           │  │  [View report + AI summary →] │                    │
│           │  └───────────────────────────────┘                    │
│           │                                                        │
│           │  ─────────────────────────────────────────────────    │
│           │                                                        │
│           │  Quick actions                                         │
│           │  ┌─────────────────────┐  ┌─────────────────────┐    │
│           │  │  + Book a new test  │  │  View all reports → │    │
│           │  └─────────────────────┘  └─────────────────────┘    │
│           │                                                        │
└───────────┴────────────────────────────────────────────────────────┘
```

**Empty state (first-time user, no appointments, no reports):**

```
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │           [illustrated flask + AI sparkle]          │
  │                                                     │
  │  Welcome to LabLumen, Sarah.                        │
  │  Book your first test to get started.               │
  │                                                     │
  │  [+ Book a lab test →]                              │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

---

### 5.4 Booking Wizard (`/app/book`)

**Layout:** Centered content (max-width 640px), sidebar navigation still visible.

**Step Indicator (always visible at top):**

```
  ① Who  ──  ② Tests  ──  ③ Date  ──  ④ Time  ──  ⑤ Confirm
  ↑ Active step is filled teal circle. Completed steps are checkmark circles.
  Upcoming steps are gray circles. Lines between them fill teal as steps complete.
```

---

**Step 1 — Who is this for?**

```
  Who is this appointment for?

  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
  │  ○              │    │  ○              │    │  ✦              │
  │  Sarah Mitchell │    │  Tom Mitchell   │    │  + Add a new    │
  │  Self           │    │  Son            │    │  person         │
  │  [✓ Select]     │    │  [  Select  ]   │    │                 │
  └─────────────────┘    └─────────────────┘    └─────────────────┘

                                               [Continue →]
```

Selected card has a teal border and a teal radio indicator. Clicking "Add a new person" slides in a right-side sheet with the profile form (6 fields, proper labels, relationship is a `<select>` with options: Self, Spouse, Child, Parent, Sibling, Other).

---

**Step 2 — Choose your tests**

```
  Which tests do you need?

  ┌──────────────────────────────────────────────────────┐
  │  Complete Blood Count (CBC)                   $45    │
  │  Measures red cells, white cells, platelets          │
  │  and hemoglobin. Most common diagnostic test.  [＋]  │
  └──────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │  Lipid Panel                                  $65    │
  │  ✓ Added                                      [─]   │
  │  Cholesterol, HDL, LDL, and triglycerides.          │
  └──────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │  Thyroid Panel (TSH)                          $80    │
  │  Thyroid-stimulating hormone level.           [＋]  │
  └──────────────────────────────────────────────────────┘

  ─────────────────────────────────────────────────────
  1 test selected · Total: $65.00

  [← Back]                                [Continue →]
```

Test cards show the description (currently unused `description` field from API). Added tests get a teal border + checkmark + "Added" label. The [+] / [−] buttons are clear add/remove actions. No checkboxes — tapping a card adds it.

---

**Step 3 — Pick a date**

```
  Choose a date

       ◁  June 2026  ▷

  Mo   Tu   We   Th   Fr   Sa   Su
                 1    2    3    4    5
  6    7    8    9    10   11   12
  13   14   15   16   17   18   19     ← today (outlined)
  20   21   22   23   24   25   26
  27   28   29   30

  Past dates: grayed out, not selectable.
  Today is outlined with teal border.
  Selected date gets solid teal fill, white text.
  Weekends can be disabled if lab is closed.

  [← Back]                             [Continue →]
```

Custom calendar component — no native `<input type="date">`. This is built with CSS grid, keyboard-navigable (arrow keys, Enter to select).

---

**Step 4 — Pick a time**

```
  Choose a time
  Friday, June 20

  Morning
  ┌───────┐  ┌───────┐  ┌───────┐  ┌───────┐
  │ 9:00  │  │ 9:30  │  │ 10:00 │  │ 10:30 │
  └───────┘  └───────┘  └───────┘  └───────┘
  ┌───────┐  ┌───────┐
  │ 11:00 │  │ 11:30 │
  └───────┘  └───────┘

  Afternoon
  ┌───────┐  ┌───────┐  ┌───────┐  ┌───────┐
  │ 2:00  │  │ 2:30  │  │ 3:00  │  │ 3:30  │
  └───────┘  └───────┘  └───────┘  └───────┘
  ┌───────┐
  │ 4:00  │
  └───────┘

  [← Back]                             [Continue →]
```

Time chips — not a dropdown. Selected chip: teal fill + white text. Keyboard navigable. Time displayed in 12-hour format (friendlier than 14:00).

---

**Step 5 — Review & Confirm**

```
  Review your appointment

  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  Patient     Sarah Mitchell (Self)                  │
  │  ─────────────────────────────────────────────────  │
  │  Tests       Lipid Panel                   $65.00   │
  │  ─────────────────────────────────────────────────  │
  │  Date        Friday, June 20, 2026                  │
  │  Time        10:00 AM                               │
  │  ─────────────────────────────────────────────────  │
  │  Total                                    $65.00    │
  │                                                     │
  │  A confirmation will be sent to                     │
  │  sarah@example.com                                  │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  [← Back]                       [Confirm & Book →]
```

**Confirmation / Success State:**

```
              ┌──────────────────────────────────────┐
              │                                      │
              │       ✓ (large animated checkmark)  │
              │                                      │
              │  Appointment confirmed!              │
              │                                      │
              │  Lipid Panel                         │
              │  Friday, June 20 · 10:00 AM          │
              │  Sarah Mitchell                      │
              │                                      │
              │  We've sent a confirmation to        │
              │  sarah@example.com                   │
              │                                      │
              │  [View appointments]                 │
              │  [← Back to home]                   │
              │                                      │
              └──────────────────────────────────────┘
```

---

### 5.5 Appointments Page (`/app/appointments`)

```
┌─ Sidebar ─┬────────────────────────────────────────────────────────┐
│           │  Appointments                                          │
│           │                                                        │
│           │  [Upcoming]  [Past]                                    │
│           │                                                        │
│           │  ─── Upcoming ──────────────────────────────────────  │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  Lipid Panel                                    │  │
│           │  │  Friday, June 20 · 10:00 AM                    │  │
│           │  │  Sarah Mitchell (Self)                          │  │
│           │  │  ● Scheduled                                    │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ─── Past Appointments ────────────────────────────  │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  CBC + Lipid Panel            Jun 18 · 09:30   │  │
│           │  │  Sarah Mitchell · Completed                     │  │
│           │  │  [View report →]                                │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  Thyroid Panel                Jun 10 · 10:00   │  │
│           │  │  Sarah Mitchell · Completed                     │  │
│           │  │  [View report →]                                │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
└───────────┴────────────────────────────────────────────────────────┘
```

Appointments with reports show a "View report →" link that navigates to `/app/reports/:id`. This connects the two primary experiences.

---

### 5.6 Reports List (`/app/reports`)

```
┌─ Sidebar ─┬────────────────────────────────────────────────────────┐
│           │  My Reports                                            │
│           │                                                        │
│           │  ┌────────────────────────────────────────────────┐   │
│           │  │  🔍  Search by test name...                   │   │
│           │  └────────────────────────────────────────────────┘   │
│           │                                                        │
│           │  [All]  [Ready]  [Processing]  [Failed]               │
│           │   ↑ Active tab has bottom teal border                  │
│           │                                                        │
│           │  ─── June 2026 ─────────────────────────────────     │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  Complete Blood Count (CBC)                     │  │
│           │  │  Sarah Mitchell · Jun 18, 2026  ● Ready        │  │
│           │  │                             [View report →]    │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  Thyroid Panel                                  │  │
│           │  │  Tom Mitchell · Jun 10, 2026   ◷ Processing    │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ─── May 2026 ──────────────────────────────────     │
│           │  ...                                                   │
│           │                                                        │
└───────────┴────────────────────────────────────────────────────────┘
```

**Status badge rules:**
- `Ready` → teal background, white text, checkmark icon
- `Processing` → amber background, white text, spinner icon (animated)
- `Failed` → red background, white text, alert icon

**Empty state (no reports yet):**

```
              [illustration: flask with sparkle]

              Your results will appear here.
              Once a lab uploads your report,
              it shows up instantly.

              [+ Book your first test →]
```

**Empty state (search returns nothing):**

```
              No results for "thyroid".
              Try a different search term.
```

---

### 5.7 Report Workspace (`/app/reports/:id`) — FLAGSHIP SCREEN

This is the most important screen in the product. Every decision here is premium.

**Desktop Layout (1280px+):**

```
┌─ Sidebar ─┬──────────── PDF Viewer ────────────┬──── AI Panel ─────┐
│  240px    │              flex-1                 │      400px         │
│           │                                    │                   │
│           │  ← Reports · CBC — Jun 18          │ [Summary] [Chat]  │
│           │                       [↓ Download] │ ─────────────────  │
│           │  ─────────────────────────────     │                   │
│           │                                    │  AI Summary       │
│           │                                    │  ───────────────  │
│           │                                    │  Your CBC results │
│           │  ┌─────────────────────────────┐   │  show all values  │
│           │  │                             │   │  within normal    │
│           │  │   PDF RENDERED VIA IFRAME   │   │  range.           │
│           │  │                             │   │                   │
│           │  │   Browser native controls   │   │  Hemoglobin       │
│           │  │   (zoom, scroll, navigate)  │   │  14.2 g/dL ✓      │
│           │  │                             │   │                   │
│           │  │                             │   │  WBC Count        │
│           │  │                             │   │  7.2 ×10³/µL ✓   │
│           │  │                             │   │                   │
│           │  └─────────────────────────────┘   │  ─ Suggested ───  │
│           │                                    │  "Is hemoglobin   │
│           │                                    │   in range?"      │
│           │                                    │  "What diet helps?│
│           │                                    │                   │
│           │                                    │  [Chat with AI →] │
│           │                                    │                   │
└───────────┴────────────────────────────────────┴───────────────────┘
```

**AI Panel — Summary tab:**

- Full markdown rendering via `react-markdown`
- Suggested questions appear below the summary as clickable chips — clicking pre-fills the chat
- "Generated Jun 18 at 3:42 PM" timestamp
- "Copy summary" button in the top-right of the panel
- Medical disclaimer: subtle banner above suggested questions ("For educational purposes only — not medical advice")
- If processing: animated skeleton where content will be

**AI Panel — Chat tab:**

```
  ← Summary  ·  Ask your report  ·  CBC                   [✕ clear]

  ────────────────────────────────────────────────────────
  [Sarah]  Is my hemoglobin in a good range for my age?

  [AI]   Your hemoglobin of 14.2 g/dL is within the
         normal range for adult women (12.0–16.0 g/dL).
         This indicates your red blood cells are carrying
         adequate oxygen...

  ────────────────────────────────────────────────────────

  ⚠️  For educational purposes only — not medical advice.

  ┌──────────────────────────────────────────┐ [Send ▶]
  │  Type your question...                   │
  └──────────────────────────────────────────┘
```

- User messages: right-aligned, teal bubble
- AI messages: left-aligned, white card with subtle shadow, markdown rendered
- Thinking state: three animated dots (not "Thinking…" text)
- Each AI message has a copy-to-clipboard icon on hover
- Chat history persists for the session (state lifted to the route level, not the component)

---

### 5.8 Family Profiles Page (`/app/family`)

```
┌─ Sidebar ─┬────────────────────────────────────────────────────────┐
│           │  Family Profiles                                       │
│           │  Manage who you can book for.                         │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  ○  Sarah Mitchell                 [Edit] [···] │  │
│           │  │     Self · DOB: Jan 15, 1990                    │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  ┌─────────────────────────────────────────────────┐  │
│           │  │  ○  Tom Mitchell                   [Edit] [···] │  │
│           │  │     Son · DOB: Mar 22, 2012                     │  │
│           │  └─────────────────────────────────────────────────┘  │
│           │                                                        │
│           │  [+ Add a family member]                              │
│           │                                                        │
└───────────┴────────────────────────────────────────────────────────┘
```

[···] opens a popover with "Edit" and "Remove" options. "Add a family member" opens the same side sheet as in the booking wizard.

---

### 5.9 Staff Operations Queue (`/staff`)

**Layout:** Sidebar (240px, staff nav) + full-width content area.

```
┌─ Sidebar ─┬────────────────────────────────────────────────────────┐
│  LabLumen │  Operations Queue                                      │
│           │  ◁  Thursday, June 19  ▷           [← Today]         │
│  ● Queue  │                                                        │
│  Reports  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────┐  │
│           │  │   12     │  │   8      │  │   3      │  │  1   │  │
│  Settings │  │ Scheduled│  │ Completed│  │  Pending │  │ AI   │  │
│  Sign out │  │          │  │ Today    │  │  Upload  │  │Failed│  │
│           │  └──────────┘  └──────────┘  └──────────┘  └──────┘  │
│  Kim Park │                                                        │
│           │  ┌────────────────────┐  [All][Pending][Done][Failed] │
│           │  │  🔍  Search name  │                               │
│           │  └────────────────────┘                               │
│           │                                                        │
│           │  Patient         Test          Time     Status         │
│           │  ─────────────────────────────────────────────────── │
│           │  John Doe  ·  CBC          09:00   ● Pending Upload   │
│           │                                     [↑ Upload PDF]    │
│           │  ─────────────────────────────────────────────────── │
│           │  Jane Smith  ·  Lipid Panel  10:30  ◷ AI Processing  │
│           │  ─────────────────────────────────────────────────── │
│           │  Bob Wilson  ·  Thyroid TSH  11:00  ✓ Ready           │
│           │  ─────────────────────────────────────────────────── │
│           │  Mary Jones  ·  CBC          14:00  ● Pending Upload  │
│           │                                     [↑ Upload PDF]    │
│           │                                                        │
└───────────┴────────────────────────────────────────────────────────┘
```

**Stat cards:**
- "Scheduled" — total for selected date
- "Completed Today" — has_report + AI ready
- "Pending Upload" — !has_report (amber)
- "AI Failed" — processing_failed (red, 0 is green)

**Upload interaction:** Clicking "↑ Upload PDF" expands the row inline to reveal a drop zone:

```
  John Doe · CBC · 09:00
  ┌─────────────────────────────────────────────────────────┐
  │        [↑] Drag PDF here, or click to browse           │
  │             Accepts: .pdf  (Max: 20 MB)                 │
  └─────────────────────────────────────────────────────────┘
  [Cancel]
```

After drop / file selected:
```
  ████████████████████░░░░░░░ 67%   Uploading CBC_JohnDoe.pdf
```

After upload:
```
  ◷ AI Processing... (live spinner)
```

After AI completes:
```
  ✓ Ready — Report available to patient
```

This is the complete status lifecycle visible to staff — no more dead-end "Uploaded — AI processing started" with no follow-up.

---

### 5.10 Staff Reports View (`/staff/reports`)

A simpler view focused on report management — not daily ops. Shows all reports ever uploaded, with their AI processing status, allowing staff to see failures and eventually trigger reprocessing.

```
  All Reports

  [All]  [Ready]  [Processing]  [Failed]

  Patient          Test          Date       AI Status    Report
  ─────────────────────────────────────────────────────────────
  John Doe         CBC           Jun 19     ✓ Ready
  Jane Smith       Lipid Panel   Jun 19     ◷ Processing
  Mary Jones       Thyroid TSH   Jun 18     ✕ Failed      [Retry]
```

"Retry" would call the same upload endpoint with the existing file — this requires no new backend work as the upload endpoint already handles this case.

---

## 6. Component Hierarchy

### Component Tree

```
App
├── PublicLayout
│   ├── LandingPage
│   │   ├── Hero
│   │   ├── HowItWorks
│   │   ├── FeatureGrid
│   │   ├── ForLabs
│   │   ├── TrustBadges
│   │   └── CallToAction
│   ├── LoginPage
│   │   ├── BrandPanel
│   │   │   └── ProductPreviewCard (glassmorphism)
│   │   └── AuthForm
│   │       ├── Input (email)
│   │       ├── PasswordInput (with show/hide toggle)
│   │       ├── ErrorBanner
│   │       └── Button (submit, with Spinner)
│   └── ForgotPasswordPage
│       └── EmailForm
│
├── PatientLayout
│   ├── PatientSidebar
│   │   ├── Logo
│   │   ├── NavItem (× N)
│   │   └── UserFooter (avatar, email, sign out)
│   │
│   ├── PatientHomePage (/app)
│   │   ├── WelcomeHeader
│   │   ├── UpcomingAppointmentCard
│   │   ├── LatestReportCard
│   │   ├── RecentReportsList
│   │   └── QuickActionButtons
│   │
│   ├── BookingWizardPage (/app/book)
│   │   ├── StepIndicator
│   │   ├── BookingStep1PatientSelect
│   │   │   ├── PatientCard (× N)
│   │   │   └── AddPatientSheet
│   │   │       └── PatientProfileForm
│   │   ├── BookingStep2TestSelect
│   │   │   └── TestCard (× N)
│   │   ├── BookingStep3DatePicker
│   │   │   └── Calendar
│   │   ├── BookingStep4TimePicker
│   │   │   └── TimeChip (× N)
│   │   ├── BookingStep5Confirm
│   │   │   └── BookingSummaryCard
│   │   └── BookingSuccessScreen
│   │
│   ├── AppointmentsPage (/app/appointments)
│   │   ├── TabBar (Upcoming, Past)
│   │   └── AppointmentCard (× N)
│   │
│   ├── ReportsListPage (/app/reports)
│   │   ├── SearchInput
│   │   ├── StatusFilterTabs
│   │   └── ReportListItem (× N)
│   │       └── StatusBadge
│   │
│   ├── ReportWorkspacePage (/app/reports/:id)
│   │   ├── ReportWorkspaceHeader (back link, title, download)
│   │   ├── PDFViewer (iframe wrapper with loading/error states)
│   │   └── AIPanel
│   │       ├── PanelTabs (Summary, Chat)
│   │       ├── SummaryView
│   │       │   ├── Markdown
│   │       │   ├── SuggestedQuestionChips
│   │       │   └── CopyButton
│   │       └── ChatView
│   │           ├── ChatMessageList
│   │           │   ├── UserMessage
│   │           │   └── AssistantMessage (with Markdown, copy)
│   │           ├── ThinkingIndicator (animated dots)
│   │           └── ChatInputForm
│   │
│   ├── FamilyProfilesPage (/app/family)
│   │   ├── ProfileCard (× N)
│   │   └── AddPatientSheet
│   │
│   └── PatientSettingsPage (/app/settings)
│
└── StaffLayout
    ├── StaffSidebar
    │   ├── Logo
    │   ├── NavItem (× N, with Badge)
    │   └── UserFooter
    │
    ├── StaffOperationsPage (/staff)
    │   ├── DateNavigator
    │   ├── MetricCards (Scheduled, Completed, Pending, Failed)
    │   ├── QueueFilters (Search, StatusTabs)
    │   └── OpsQueueTable
    │       └── OpsQueueRow
    │           └── UploadZone (inline expandable)
    │               └── ProgressBar
    │
    └── StaffReportsPage (/staff/reports)
        ├── StatusFilterTabs
        └── ReportManagementTable
            └── ReportManagementRow
```

### New Primitive Components (ui/ directory)

| Component | File | Priority | Description |
|-----------|------|----------|-------------|
| `Input` | `ui/input.tsx` | Critical | Shared text input with label, placeholder, focus ring, error state |
| `PasswordInput` | `ui/password-input.tsx` | Critical | Input + show/hide toggle |
| `Select` | `ui/select.tsx` | Critical | Styled native select with chevron icon |
| `Badge` | `ui/badge.tsx` | High | Status chip: variant = ready, processing, failed, pending, scheduled |
| `Skeleton` | `ui/skeleton.tsx` | High | Animated shimmer placeholder |
| `Tabs` | `ui/tabs.tsx` | High | Tab bar with active underline indicator |
| `Calendar` | `ui/calendar.tsx` | High | Custom date picker (CSS grid, keyboard navigable) |
| `Spinner` | `ui/spinner.tsx` | High | Animated loading indicator (ring or dots) |
| `Toast` | `ui/toast.tsx` | High | Transient notification (success / error / info) |
| `Sheet` | `ui/sheet.tsx` | High | Right-side slide-in panel (for profile forms, mobile menus) |
| `EmptyState` | `ui/empty-state.tsx` | High | Illustrated empty view with icon slot, headline, body, CTA |
| `StepIndicator` | `ui/step-indicator.tsx` | High | Linear multi-step progress (numbered, with completion state) |
| `Avatar` | `ui/avatar.tsx` | Medium | User initials / photo in a circle |
| `Tooltip` | `ui/tooltip.tsx` | Medium | Hover label for icon-only buttons |
| `ProgressBar` | `ui/progress-bar.tsx` | Medium | Upload progress, linear fill |
| `FormField` | `ui/form-field.tsx` | Medium | Label + Input + error message wrapper |
| `TimeChip` | `ui/time-chip.tsx` | Medium | Selectable time button (for booking step 4) |

### Existing Components to Keep

| Component | Action | Notes |
|-----------|--------|-------|
| `Button` | Keep + extend | Add `loading` variant (spinner inside), `destructive` variant |
| `Card` family | Keep + extend | Add `CardFooter`, `CardDescription` sub-components |
| `BentoCard` | Keep but scope | Use only in staff metrics area; patient experience uses purpose-built layouts |
| `ProtectedRoute` | Keep | No changes needed |
| `lib/api.ts` | Keep | Add `listMyAppointments` usage in new pages |
| `lib/auth.ts` | Keep | No changes |
| `lib/AuthContext.tsx` | Keep | No changes |
| `lib/queryClient.ts` | Keep | No changes |
| `useReports` | Keep | Excellent polling logic |
| `useOps` | Keep | No changes |
| `useLabTests` | Keep | No changes |
| `usePatients` | Keep | No changes |

### Dead Code to Delete

| Component | Action |
|-----------|--------|
| `ReportChatModal.tsx` | Delete — dead code, never rendered |

---

## 7. Design System

### Typography

**Font:** Geist (by Vercel). Free, professional, designed for interfaces. Excellent legibility at small sizes. Feels modern and premium without being frivolous.

**Fallback stack:** `"Geist", "Inter", system-ui, sans-serif`

**Loading:** Via `@fontsource/geist` npm package or CDN via `<link>` preload.

**Type Scale:**

| Token | Size | Weight | Line Height | Use Case |
|-------|------|--------|-------------|---------|
| `display-lg` | 48px / 3rem | 700 | 1.1 | Hero headlines (landing page) |
| `display-sm` | 36px / 2.25rem | 700 | 1.2 | Section headlines |
| `heading-lg` | 24px / 1.5rem | 600 | 1.3 | Page titles |
| `heading-md` | 20px / 1.25rem | 600 | 1.4 | Card titles, section labels |
| `heading-sm` | 16px / 1rem | 600 | 1.4 | Widget headers |
| `body-lg` | 16px / 1rem | 400 | 1.6 | Body text, paragraph content |
| `body-md` | 14px / 0.875rem | 400 | 1.5 | Most UI text, list items |
| `body-sm` | 13px / 0.8125rem | 400 | 1.5 | Secondary text, timestamps |
| `label` | 12px / 0.75rem | 500 | 1.4 | Form labels, eyebrow text |
| `caption` | 11px / 0.6875rem | 400 | 1.4 | Meta text, footnotes |

Note: `caption` (11px) should be used sparingly and only on white backgrounds where it meets WCAG AA at `#475569` or darker.

---

### Color System

**Primary Palette:**

| Token | Value | Usage |
|-------|-------|-------|
| `primary-50` | `#F0FDFA` | Light teal backgrounds, hover states |
| `primary-100` | `#CCFBF1` | Teal-tinted surfaces |
| `primary-500` | `#14B8A6` | Hover states, secondary actions |
| `primary-600` | `#0D9488` | Primary CTA, active nav, logo |
| `primary-700` | `#0F766E` | Dark brand, pressed states |
| `primary-900` | `#134E4A` | Deep teal for dark brand moments |

The primary color changes from `#008080` (CSS `teal`, slightly flat) to `#0D9488` (teal-600 from Tailwind — richer, more sophisticated).

**Neutral Palette:**

| Token | Value | Usage |
|-------|-------|-------|
| `neutral-0` | `#FFFFFF` | Card backgrounds, input backgrounds |
| `neutral-50` | `#F8FAFC` | Page background (surface-1) |
| `neutral-100` | `#F1F5F9` | Elevated surface (surface-2) |
| `neutral-200` | `#E2E8F0` | Borders, dividers |
| `neutral-300` | `#CBD5E1` | Disabled borders |
| `neutral-400` | `#94A3B8` | Placeholder text, tertiary |
| `neutral-500` | `#64748B` | Caption text (only on white, 12px+) |
| `neutral-600` | `#475569` | Secondary text (WCAG AA at 12px+) |
| `neutral-700` | `#334155` | Muted primary text |
| `neutral-900` | `#0F172A` | Primary text |

**Semantic Colors (WCAG AA corrected):**

| Token | Value | Contrast on white | Usage |
|-------|-------|-------------------|-------|
| `success-500` | `#059669` | 4.55:1 ✓ | Success text, Ready badges |
| `success-50` | `#ECFDF5` | — | Success backgrounds |
| `warning-500` | `#D97706` | 4.52:1 ✓ | Warning text, Processing badges |
| `warning-50` | `#FFFBEB` | — | Warning backgrounds |
| `danger-500` | `#DC2626` | 4.66:1 ✓ | Error text, Failed badges |
| `danger-50` | `#FEF2F2` | — | Error backgrounds |
| `info-500` | `#2563EB` | 5.9:1 ✓ | Info messages |
| `info-50` | `#EFF6FF` | — | Info backgrounds |

All semantic text colors now pass WCAG AA (4.5:1 minimum) on white backgrounds.

**AI Brand Gradient (for accents and the AI panel header):**

```
background: linear-gradient(135deg, #0D9488, #0EA5E9);
```

Teal-to-sky. Used sparingly: AI panel header accent, AI feature badges, suggested question chips.

**Glassmorphism (3 sanctioned uses only):**

```css
/* Login brand panel — on dark gradient background */
background: rgba(255, 255, 255, 0.08);
backdrop-filter: blur(20px);
border: 1px solid rgba(255, 255, 255, 0.12);

/* Report workspace AI panel — subtle depth separator */
/* Not glass — use solid white surface with elevation shadow */

/* Mobile bottom sheet backdrop */
background: rgba(15, 23, 42, 0.5);
backdrop-filter: blur(8px);
```

Glassmorphism is not used on cards, nav items, or anywhere else. It is a depth signal, not a decoration.

---

### Spacing System

Built on Tailwind's 4px base grid. Key reference values:

| Token | Value | Use Case |
|-------|-------|---------|
| `space-1` | 4px | Tight internal spacing (icon + label gap) |
| `space-2` | 8px | Small gaps (badge padding, tight rows) |
| `space-3` | 12px | Default input padding, button padding-x |
| `space-4` | 16px | Standard gap between form fields |
| `space-5` | 20px | Card header padding |
| `space-6` | 24px | Card content padding, section gaps |
| `space-8` | 32px | Component group spacing |
| `space-10` | 40px | Section spacing within a page |
| `space-12` | 48px | Major section breaks |
| `space-16` | 64px | Landing page section spacing |

---

### Border Radius System

| Token | Value | Use Case |
|-------|-------|---------|
| `radius-sm` | 6px | Badges, chips, small buttons |
| `radius-md` | 8px | Inputs, selects, small cards |
| `radius-lg` | 12px | Buttons, toast notifications |
| `radius-xl` | 16px | Cards (current `rounded-bento`) |
| `radius-2xl` | 24px | Large panels, hero sections |
| `radius-full` | 9999px | Avatars, step indicator circles, FABs |

---

### Elevation System

| Level | Shadow | Use Case |
|-------|--------|---------|
| `elevation-0` | none | Flat rows, dividers |
| `elevation-1` | `0 1px 3px rgba(0,0,0,0.08), 0 1px 2px rgba(0,0,0,0.04)` | Report list items, appointment cards |
| `elevation-2` | `0 4px 16px rgba(0,0,0,0.08), 0 2px 8px rgba(0,0,0,0.04)` | Main cards, sidebar |
| `elevation-3` | `0 8px 32px rgba(0,0,0,0.12), 0 4px 16px rgba(0,0,0,0.06)` | Sheets, popovers, toasts |
| `elevation-4` | `0 16px 48px rgba(0,0,0,0.16), 0 8px 24px rgba(0,0,0,0.08)` | Modal overlays, bottom drawers |

The teal-tinted shadow (`rgba(0, 128, 128, 0.05)`) from the current design is preserved for the main card shadow — it is a subtle brand touch. Elevation-1 uses neutral shadows.

---

### Component Specifications

**Button:**

```
variant:
  default    → primary-600 bg, white text, primary-700 on hover
  outline    → white bg, neutral-200 border, neutral-900 text
  ghost      → transparent bg, neutral-600 text, neutral-100 on hover
  destructive → danger-500 bg, white text
  loading    → disabled state + spinner inside

size:
  sm    → h-8  px-3  text-sm    (for table actions)
  md    → h-10 px-4  text-sm    (default)
  lg    → h-12 px-6  text-base  (primary CTAs)
  icon  → h-10 w-10             (icon-only)
  icon-sm → h-8 w-8             (compact icon-only)

focus: ring-2 ring-primary-500 ring-offset-2
disabled: opacity-50 cursor-not-allowed
```

**Badge:**

```
variant:
  ready       → success-50 bg, success-500 text, ✓ icon
  processing  → warning-50 bg, warning-500 text, ◷ animated spinner
  failed      → danger-50 bg, danger-500 text, ✕ icon
  pending     → neutral-100 bg, neutral-600 text, ● icon
  scheduled   → primary-50 bg, primary-600 text, 📅 icon

size:
  sm  → px-2 py-0.5 text-xs
  md  → px-2.5 py-1 text-sm

border-radius: radius-full
font-weight: 500
```

**Input:**

```
height: h-10 (40px)
border: neutral-200, 1px
border-radius: radius-md (8px)
background: white
padding: px-3
font-size: text-sm

focus:
  border-color: primary-600
  ring: 2px ring-primary-600/20

error:
  border-color: danger-500
  ring: 2px ring-danger-500/20

disabled:
  background: neutral-50
  cursor: not-allowed
  opacity: 0.7
```

**Skeleton:**

Shimmer animation from left to right. Shape matches the content it replaces exactly:

```
@keyframes shimmer {
  from { background-position: -200% 0; }
  to   { background-position: 200% 0; }
}

background: linear-gradient(90deg,
  neutral-100 25%,
  neutral-200 50%,
  neutral-100 75%
);
background-size: 200% 100%;
animation: shimmer 1.5s infinite;
```

Skeleton variants: `text` (h-4 rounded), `heading` (h-6 rounded), `card` (full card shape), `avatar` (circle).

---

## 8. Layout Specifications

### Page Layout — Patient App

```
viewport
└── flex row, min-h-screen
    ├── Sidebar [position: fixed, width: 240px, left: 0, top: 0, bottom: 0]
    │   z-index: 30
    │   background: white
    │   border-right: 1px solid neutral-200
    │   elevation: 2
    │
    └── Main content [margin-left: 240px, flex: 1]
        └── page content area
            max-width: none (fluid)
            padding: 32px 40px (desktop), 16px (mobile)
```

Individual pages define their own internal max-width if needed (e.g., booking wizard: max-w-2xl centered).

### Page Layout — Staff App

Identical structure to Patient App. Staff content is generally full-width (tables, queues benefit from space).

### Report Workspace Layout

```
[Sidebar 240px] | [PDF Viewer flex-1] | [AI Panel 400px]
                  min-width: 400px      fixed width on desktop
                                        collapses to tabs on mobile
```

The AI panel is NOT resizable in the initial implementation (adds complexity). Set at 400px — significantly wider than the current 30% (which was ~345px at 6xl).

### Landing Page Layout

Full-width with a max-width container (1280px) centered. Sections use alternating background colors (white / neutral-50).

### Authentication Layout (Login / Forgot Password)

```
min-h-screen flex
├── Left brand panel  [width: 55%, display: hidden on mobile]
│   background: linear-gradient(160deg, primary-900, primary-700, neutral-900)
│
└── Right auth panel  [width: 45%, display: full-width on mobile]
    background: white
    padding: 48px 64px (desktop), 24px (mobile)
```

### Booking Wizard Layout

```
Sidebar | Centered wizard content
         max-width: 640px
         margin: 0 auto
         padding-top: 40px
         padding-bottom: 80px (space for sticky step indicator)
```

Step indicator: sticky below the page header, above the step content. Travels with the user as they scroll.

---

## 9. Motion Guidelines

### Principles

Motion should be:
- **Functional** — clarify what happened, what is next
- **Proportional** — small actions get subtle motion, major transitions get more
- **Additive** — motion adds meaning, not just decoration

### Duration Scale

| Token | Duration | Use Case |
|-------|----------|---------|
| `duration-instant` | 50ms | Hover state changes, button press |
| `duration-fast` | 100ms | Focus rings, badge flips |
| `duration-normal` | 200ms | Panel transitions, page element entrance |
| `duration-slow` | 350ms | Sheet slide-in, modal fade |
| `duration-deliberate` | 500ms | Page-level transitions, success animations |

All motion respects `prefers-reduced-motion: reduce`. When reduced motion is active, use `opacity` only (no translate, no scale).

### Easing Functions

| Token | Value | Use Case |
|-------|-------|---------|
| `ease-out` | `cubic-bezier(0.16, 1, 0.3, 1)` | Elements entering the screen |
| `ease-in` | `cubic-bezier(0.7, 0, 0.84, 0)` | Elements leaving |
| `ease-in-out` | `cubic-bezier(0.6, 0, 0.4, 1)` | Panel switches, tab transitions |
| `ease-spring` | `cubic-bezier(0.34, 1.56, 0.64, 1)` | Micro-interactions (button press, selection) |

### Specific Motion Definitions

**Page transitions (route changes):**
```
Incoming page: opacity 0 → 1, translateY 8px → 0
Duration: 200ms ease-out
Outgoing: opacity 1 → 0
Duration: 150ms ease-in
```

**Sidebar navigation active state:**
```
Background: width 0 → full, duration 150ms ease-out
Left border: height 0 → full, duration 150ms ease-out
Text color: instant (50ms)
```

**Sheet / drawer slide-in:**
```
Transform: translateX(100%) → 0
Duration: 350ms ease-out
Backdrop: opacity 0 → 0.5, duration 300ms
```

**Step indicator progression:**
```
When step completes: circle fills teal (scale 0.8 → 1, duration 200ms spring)
Connecting line fills left to right: width 0% → 100%, duration 300ms ease-out
```

**Booking success (checkmark):**
```
Checkmark SVG: stroke-dashoffset animation (draw from scratch)
Duration: 500ms ease-out
Circle expand: scale 0 → 1, duration 400ms spring
```

**AI thinking indicator (3 dots):**
```
Three dots, each bouncing with 100ms delay between them
translateY: 0 → -4px → 0
Duration: 600ms each, infinite loop
Delay: dot1: 0ms, dot2: 100ms, dot3: 200ms
```

**Report chat message arrival:**
```
Incoming message: opacity 0 → 1, translateY 4px → 0
Duration: 200ms ease-out
Stagger if multiple: 50ms between messages
```

**Toast notification:**
```
Enter: translateX(full) → 0, opacity 0 → 1, duration 350ms ease-out
Exit: opacity 1 → 0, duration 200ms ease-in
Auto-dismiss: 4000ms
Position: bottom-right on desktop, bottom-center on mobile
```

**Upload progress bar:**
```
Width: 0% → N%, smooth transition
Duration: continuous, reflects real progress
Color: primary-600 fill on neutral-100 track
```

**Skeleton loading → content:**
```
Skeleton fades out: opacity 1 → 0, duration 200ms
Content fades in: opacity 0 → 1, duration 200ms, delayed 100ms
Stagger in list: 50ms between items
```

**Button hover:**
```
Background: instant color shift (no transition — too slow at 50ms+)
Scale on press: scale 0.97, duration 50ms
```

**Card hover (report list, appointment cards):**
```
Box-shadow: elevation-1 → elevation-2, duration 150ms ease-out
translateY: 0 → -1px, duration 150ms ease-out
```

**Status badge (Processing → Ready):**
```
Cross-fade: old badge opacity 1 → 0 simultaneously with new badge 0 → 1
Duration: 300ms
```

---

## 10. Mobile Strategy

### Breakpoints

| Breakpoint | Width | Strategy |
|------------|-------|----------|
| `mobile` | < 640px | Single column, bottom tab nav, full-width sheets |
| `tablet` | 640–1024px | Single column, sidebar collapses to hamburger, top header |
| `desktop` | 1024px+ | Two-column layouts, persistent sidebar |

### Sidebar Behavior on Mobile / Tablet

- Sidebar is hidden by default on mobile/tablet
- A hamburger menu in the top header opens the sidebar as a full-height Sheet from the left
- Backdrop closes the sidebar on tap
- Bottom tab bar provides primary navigation on mobile

### Critical Mobile Fixes (from current broken state)

**Report workspace on mobile:**

Instead of 70/30 fixed split, use a tab layout:

```
┌────────────────────────────────┐
│  ← Reports · CBC · [↓ PDF]   │  ← page header (sticky)
├────────────────────────────────┤
│  [Summary]  [PDF]  [Chat]     │  ← tabs (sticky below header)
├────────────────────────────────┤
│                                │
│  Active tab content scrolls    │
│  here in a single column       │
│                                │
└────────────────────────────────┘
```

The PDF tab renders the iframe full-height. The Summary and Chat tabs render text content that scrolls naturally. No fixed percentage widths anywhere.

**Booking wizard on mobile:**

Each step takes the full viewport height. The step indicator collapses to just the current step number and label ("Step 2 of 5 — Choose tests") with a progress bar below. Full calendar and time chips stack vertically.

**Staff operations on mobile:**

Table is replaced by a card list (each `OpsQueueRow` becomes an `OpsQueueCard`). Upload zone opens as a bottom Sheet. Metric cards stack 2×2 in a grid.

### Touch Targets

All interactive elements must meet the 44×44px minimum touch target:
- Buttons: `h-10` (40px) → upgrade primary buttons to `h-11` (44px) on mobile
- Time chips: minimum 44×44px on mobile
- Nav items: minimum 44px tall
- Close / back / action buttons: minimum 44×44px
- FABs: 56×56px minimum

### Form Experience on Mobile

- All inputs: 16px minimum font size (prevents iOS auto-zoom)
- Full-width inputs on mobile
- Native keyboard types: `type="email"`, `type="tel"`, `inputmode="numeric"`
- Date picker (booking step 3): custom calendar scrollable component on mobile, not native date input
- No 2-column form grids on mobile (single column only)

---

## 11. Desktop Strategy

### Wide-Screen Handling

At viewports wider than 1440px, the sidebar remains fixed at 240px and the content area expands without a hard max-width cap (except for the booking wizard, which stays max-w-2xl centered). This prevents the empty margins that plague the current `max-w-6xl` approach on 27" monitors.

### Report Workspace on Desktop

The AI panel is fixed at 400px. This is wider than the current 30% (~345px) and significantly more comfortable for reading long AI responses with lab values. The PDF viewer gets the remaining space (flex-1), which on a 1440px screen (minus 240px sidebar, minus 400px AI panel) = 800px of PDF space. This is generous and professional.

### Keyboard Navigation (Design for it from the start)

| Shortcut | Action |
|----------|--------|
| `Escape` | Close any open sheet, popover, or navigate back (in booking wizard) |
| `→` `←` | Navigate between booking wizard steps (when no input is focused) |
| `↑` `↓` | Navigate through report list items |
| `Enter` | Select focused booking step option, submit focused form |
| `Tab` | Standard focus order — always well-defined |
| `Shift+Tab` | Reverse focus order |

All modals and sheets use a focus trap. Focus returns to the trigger element on close.

### Hover States

Every interactive element has a distinct hover state. There should be no ambiguity about what is clickable. Define:
- Sidebar nav items: `primary-50` background fill
- Report list items: `neutral-50` background + `elevation-1` shadow + subtle upward translate
- Buttons: see Button spec above
- Time chips: `primary-50` background
- Test cards in booking: `primary-50` border + `primary-50` background

---

## 12. Implementation Roadmap

### Phase 0 — Foundation (Days 1–3)

Prerequisites that all other work depends on. No new pages yet.

**Design System:**
- [ ] Install Geist font (`@fontsource/geist`)
- [ ] Update `tailwind.config.ts` with new color tokens (primary scale, neutral scale, WCAG-corrected semantics)
- [ ] Update `theme/tokens.ts` to match
- [ ] Update `index.css` with base font family

**New Primitives:**
- [ ] Create `ui/input.tsx`
- [ ] Create `ui/password-input.tsx` (extends Input)
- [ ] Create `ui/select.tsx`
- [ ] Create `ui/badge.tsx`
- [ ] Create `ui/skeleton.tsx`
- [ ] Create `ui/spinner.tsx`
- [ ] Create `ui/toast.tsx` + `useToast` hook
- [ ] Create `ui/tabs.tsx`
- [ ] Create `ui/sheet.tsx`
- [ ] Create `ui/empty-state.tsx`
- [ ] Create `ui/avatar.tsx`
- [ ] Create `ui/step-indicator.tsx`
- [ ] Create `ui/progress-bar.tsx`
- [ ] Create `ui/time-chip.tsx`

**Accessibility baseline:**
- [ ] Delete `ReportChatModal.tsx` (dead code)
- [ ] Fix WCAG contrast for success/warning/danger tokens
- [ ] Add skip-to-content link to Layout

---

### Phase 1 — Navigation & Shell (Days 4–6)

**Routing:**
- [ ] Update `App.tsx` with new route structure (`/app/*`, `/staff/*`, public routes)
- [ ] Create `PatientLayout.tsx` — sidebar + content shell
- [ ] Create `StaffLayout.tsx` — sidebar + content shell
- [ ] Create `PatientSidebar.tsx`
- [ ] Create `StaffSidebar.tsx`
- [ ] Mobile: create bottom tab bar component
- [ ] Mobile: sidebar opens as Sheet on mobile

**Auth pages:**
- [ ] Redesign `Login.tsx` → split-panel layout
- [ ] Add password show/hide toggle
- [ ] Add spinner to submit button
- [ ] Add "Forgot password?" link
- [ ] Create `/forgot-password` page (Cognito flow)

---

### Phase 2 — Report Workspace (Days 7–11)

The flagship experience. Highest return on investment.

- [ ] Create `/app/reports` list page with `SearchInput`, `StatusFilterTabs`, `ReportListItem`, skeleton loading, empty state
- [ ] Create `/app/reports/:id` page — `ReportWorkspacePage`
  - [ ] `ReportWorkspaceHeader` (breadcrumb, title, download)
  - [ ] `PDFViewer` component (iframe with loading + error states)
  - [ ] `AIPanel` with tab structure (Summary / Chat)
  - [ ] `SummaryView` — markdown, copy button, timestamp, suggested questions
  - [ ] `ChatView` — messages, animated dots thinking indicator, disclaimer banner, copy per-message
  - [ ] Mobile: tab layout replacing 70/30 split
  - [ ] Lift chat state to route level (persists across tab switch)
  - [ ] Connect suggested questions → pre-fill chat
  - [ ] Wire Escape key (navigate back, not modal dismiss)
- [ ] Remove `ReportPreviewModal` from `PatientDashboard`
- [ ] Update `useReports` scope to new route

---

### Phase 3 — Patient Home & Booking Wizard (Days 12–17)

- [ ] Create `PatientHomePage` (`/app`)
  - [ ] Welcome header (greeting + date)
  - [ ] Upcoming appointment widget (wired to `listMyAppointments`)
  - [ ] Latest report widget
  - [ ] Quick action buttons
  - [ ] Empty state for new users
- [ ] Create booking wizard (`/app/book`) — 5 steps
  - [ ] `StepIndicator`
  - [ ] `BookingStep1PatientSelect` — card grid of patient profiles
  - [ ] `AddPatientSheet` — profile form in a Sheet, relationship as `<Select>`
  - [ ] `BookingStep2TestSelect` — test cards with description and add/remove
  - [ ] `BookingStep3DatePicker` — custom `Calendar` component
  - [ ] `BookingStep4TimePicker` — time chips, grouped Morning / Afternoon
  - [ ] `BookingStep5Confirm` — summary card, confirm button, email note
  - [ ] `BookingSuccessScreen` — animated checkmark, confirmation details
- [ ] Create `FamilyProfilesPage` (`/app/family`)
- [ ] Create `AppointmentsPage` (`/app/appointments`)
  - [ ] Tab: Upcoming / Past
  - [ ] Wire `listMyAppointments` API (currently defined, never used)
  - [ ] "View report →" links from past appointments

---

### Phase 4 — Staff Dashboard Redesign (Days 18–22)

- [ ] Redesign `StaffOperationsPage` (`/staff`)
  - [ ] Date navigator (defaults to today)
  - [ ] `MetricCards` (4 cards: Scheduled, Completed, Pending Upload, AI Failed)
  - [ ] `QueueFilters` — search input + status filter tabs
  - [ ] `OpsQueueTable` — sortable header columns
  - [ ] Extract `OpsQueueRow` to its own file
  - [ ] Inline `UploadZone` (drag-and-drop + progress bar)
  - [ ] AI processing status in row after upload (polling-aware)
  - [ ] Mobile: card list layout replacing table
- [ ] Create `StaffReportsPage` (`/staff/reports`)
  - [ ] Status filter tabs
  - [ ] Report management table with AI status and retry action
- [ ] Wire `updateAppointmentStatus` API (appointment status dropdown per row)

---

### Phase 5 — Landing Page & Polish (Days 23–27)

- [ ] Create landing page (`/`) for anonymous visitors
  - [ ] Hero section with product preview
  - [ ] How It Works (3 steps)
  - [ ] Feature grid
  - [ ] For Labs section
  - [ ] Trust indicators
  - [ ] Final CTA
- [ ] Implement toast notifications throughout (booking success, upload success, errors)
- [ ] Add empty state illustrations to all list views
- [ ] Implement skeleton loading for all async content
- [ ] Add page transition animations (opacity + translateY)
- [ ] AI panel: animated thinking dots (replace "Thinking…")
- [ ] Booking success: animated checkmark SVG
- [ ] Sheet slide-in animations
- [ ] Patient settings page

---

### Phase 6 — Accessibility & Launch Readiness (Days 28–30)

- [ ] Focus trap on all Sheet components
- [ ] `aria-live="polite"` on all loading and feedback regions
- [ ] `aria-labelledby` on all dialog/modal-pattern components
- [ ] Skip-to-content link functional
- [ ] All semantic colors WCAG AA verified
- [ ] All touch targets 44px minimum verified
- [ ] Keyboard navigation tested end-to-end (patient flow + staff flow)
- [ ] iOS Safari PDF iframe fallback ("Open PDF in new tab" link)
- [ ] Test on: Chrome, Firefox, Safari, iOS Safari, Chrome Android
- [ ] Lighthouse audit (target: Performance ≥ 85, Accessibility ≥ 95)
- [ ] Screen reader testing (VoiceOver on macOS, TalkBack on Android)

---

### Priority Matrix

| Phase | Impact | Effort | Priority |
|-------|--------|--------|----------|
| 0 — Foundation | Unlocks all else | Low | Ship first |
| 2 — Report Workspace | Highest user value, core differentiator | Medium | Ship second |
| 1 — Navigation & Shell | Required for Phase 2 | Low | Ship with Phase 2 |
| 3 — Patient Home + Booking | High conversion impact | Medium | Ship third |
| 4 — Staff Dashboard | Ops quality, staff retention | Medium | Ship fourth |
| 5 — Landing Page + Polish | First impressions, conversion | Medium | Ship fifth |
| 6 — A11y + Launch | Required for public launch | Low | Ship last |

---

### What Does NOT Change

| Category | Items |
|----------|-------|
| Backend APIs | All existing endpoints preserved. No new API required except potentially a time-slot availability endpoint (currently hardcoded). |
| Authentication | AWS Cognito, SRP flow, role-based routing — unchanged. |
| Data models | All TypeScript types preserved. No schema changes. |
| Hooks | `useReports`, `useOps`, `useLabTests`, `usePatients` — unchanged. `useReports` polling logic is kept exactly as-is. |
| Business logic | Booking payload shape, chat history passing, PDF presigned URL — all unchanged. |
| AI capabilities | Summary generation, multi-turn chat — unchanged. The redesign surfaces these better; it does not change them. |

---

### Expected Quality Delta

| Dimension | Current | Target | Change |
|-----------|---------|--------|--------|
| Patient booking experience | 4/10 | 9/10 | +125% |
| Report / AI experience | 6/10 | 9.5/10 | +58% |
| Staff operations | 4/10 | 8.5/10 | +112% |
| Mobile experience | 2/10 | 8/10 | +300% |
| Accessibility | 3/10 | 9/10 | +200% |
| Brand impression | 4/10 | 9/10 | +125% |
| Information architecture | 3.5/10 | 9/10 | +157% |
| Overall product feel | 5/10 | 9/10 | +80% |

---

> The product is already good. The engineering is solid. The AI works. The data model is right. This redesign's job is to build a front door worthy of what's behind it — and then make sure every room beyond the front door is as polished as what earned the invitation.

---

*LabLumen Frontend Vision — v1.0*
*Head of Product Design, UX & Frontend Architecture*
*June 19, 2026*
