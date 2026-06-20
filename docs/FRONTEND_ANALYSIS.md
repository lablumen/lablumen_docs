# LabLumen Frontend Analysis
**Design Review — Launch Readiness Audit**
*Prepared: June 18, 2026 | Reviewer: Principal Product Designer perspective*

---

## Executive Summary

| Dimension | Score | Verdict |
|-----------|-------|---------|
| **Overall Frontend** | **5 / 10** | Functional MVP. Not launch-ready. |
| **UX** | **4 / 10** | Missing critical user journeys. Booking flow is under-designed. |
| **UI** | **5.5 / 10** | Coherent visual language. Sparse and unfinished in detail. |
| **Information Architecture** | **3.5 / 10** | 3 pages for a product with this scope is a structural problem. |
| **Accessibility** | **3 / 10** | Partial compliance only. Several WCAG failures. |
| **Mobile Readiness** | **3 / 10** | The report modal is completely broken on mobile. |
| **Launch Readiness** | **4 / 10** | Serviceable for closed beta. Not for public launch. |

---

### Biggest Strengths

1. **Clean, modern code architecture** — React Query, TypeScript strict mode, Cognito auth, and clear separation of concerns. The engineering foundation is solid.
2. **Distinct visual identity** — The teal primary + bento card aesthetic is cohesive, memorable, and appropriate for a healthcare/tech product.
3. **AI-first report experience** — The 70/30 PDF + AI sidebar in the report modal is a genuinely differentiated UX pattern. The concept is right.
4. **Token-based design system** — A `tokens.ts` + `tailwind.config.ts` pairing provides a real foundation. Not an afterthought.
5. **Polling-aware data fetching** — The `useReports` hook that polls only while processing is intelligent product thinking.

### Biggest Weaknesses

1. **3 pages for the entire product** — Login, PatientDashboard, StaffDashboard. This is not an app. It is a prototype.
2. **The report modal is the product's core feature and it breaks on mobile** — 70/30 fixed-width split in a modal on a 375px screen is unusable.
3. **No password reset, no email verification, no forgot-password flow** — This is a hard blocker for public launch.
4. **The booking experience is one form embedded in a dashboard card** — This is healthcare scheduling for a real clinic. It deserves a guided, step-by-step experience with calendar UI.
5. **`ReportChatModal.tsx` is dead code** — It is defined, implemented, and never rendered. The app has duplicate, divergent chat implementations.
6. **Staff dashboard has zero filtering, search, or date navigation** — A lab tech managing 50+ daily orders cannot function with this UI.

### Highest-Impact Redesign Opportunities

1. **Expand routing** — Add dedicated pages: `/book`, `/reports`, `/reports/:id`, `/appointments`, `/account`
2. **Redesign the booking flow** — Replace the embedded form with a multi-step wizard with visual calendar
3. **Fix mobile report modal** — Collapse to tabbed layout below 768px
4. **Build onboarding** — First-run experience for new patient accounts
5. **Staff queue filters** — Date picker, patient search, status filter, test-type filter

---

## Product Understanding

### What Is This Product?

LabLumen is a **healthcare diagnostics SaaS platform** for independent or small-chain clinical laboratories. It enables patients to book lab tests online, receive their results as PDFs, read AI-generated plain-language summaries, and interact with those results through a natural language chat interface.

For lab staff, it provides an operations dashboard to track daily appointment volumes, upload result PDFs against patient orders, and monitor pending uploads.

### Who Are the Users?

| User Type | Profile | Primary Need |
|-----------|---------|--------------|
| **Patient** | Healthcare consumer, potentially anxious about results, varying tech literacy | Book tests easily, understand results without needing a doctor for every question |
| **Lab Staff / Nurse** | Clinical operations, high volume, time-constrained | Upload results quickly, see what's pending today, not miss anyone |
| **Lab Admin** | Implied but not yet implemented | Manage catalog, users, pricing |

### User Roles

- **Patient** — Maps to Cognito group (not `LAB_STAFF`, not `LAB_ADMIN`). Accesses `/`
- **Lab Staff** — Cognito group `LAB_STAFF`. Accesses `/staff`
- **Lab Admin** — Cognito group `LAB_ADMIN`. Also accesses `/staff` (same UI, no role differentiation in the frontend beyond access control)

*Note: Admin and Staff share the same dashboard. There is no admin-specific UI.*

### Core Value Proposition

> A patient books a blood test online, walks in, walks out, and within hours has their results explained in plain language by an AI that can answer their follow-up questions — without waiting for a doctor callback.

This is a genuinely compelling, differentiated product. The UX just hasn't caught up to the vision yet.

### Investor Pitch Summary

LabLumen bridges the gap between clinical laboratory operations and the patient experience. It digitizes test booking (replacing phone calls and walk-ins), automates the report delivery pipeline, and adds an AI interpretation layer that reduces patient anxiety and follow-up doctor visits. The platform reduces administrative overhead for labs while giving patients the health literacy they have historically needed a clinician for.

---

## Frontend Technology Audit

| Category | Technology | Assessment |
|----------|------------|------------|
| **Framework** | React 18.3 | Correct choice. Hooks, concurrent rendering ready. |
| **Build Tool** | Vite 5.4 | Fast, modern. Correct choice. |
| **Language** | TypeScript 5.5 (strict) | Correct. Types are well-used throughout. |
| **Routing** | React Router v6 (nested routes) | Correct but severely underused. Only 3 routes for a product that needs 10+. |
| **State Management** | React Context (auth) + TanStack Query v5 (server state) + useState (UI) | Appropriate pattern. No over-engineering. |
| **Styling** | Tailwind CSS v3.4 + custom tokens | Good foundation. Minor inconsistencies (raw inputs vs. styled components). |
| **UI Components** | shadcn/ui pattern (CVA + cn) — only Button and Card | Starting point only. No Input, Select, Checkbox, Badge, Toast, Dialog primitives yet. |
| **Icons** | Lucide React | Correct choice. |
| **Data Fetching** | TanStack React Query v5 | Correct. queryClient config is solid (30s stale time, 1 retry, no refetch on focus). |
| **Authentication** | AWS Cognito (amazon-cognito-identity-js, SRP flow) | Functional. JWT in localStorage is a known security trade-off. |
| **Forms** | Plain React useState | Acceptable for current complexity. Will become painful as forms grow. |
| **Markdown Rendering** | react-markdown | Correct for AI responses. |

### Maintainability Assessment

The codebase is **well-structured for its current size**. At scale it will face:

- `BookingWorkspace.tsx` is already 150+ lines managing 7 separate state variables — it needs decomposition
- `ReportPreviewModal.tsx` is 200+ lines with dual-panel state — needs decomposition
- Raw HTML `<input>`, `<select>`, `<label>` elements are inconsistently styled inline throughout; they are not extracted into shared primitives
- No Input, Select, or Checkbox component — every form field is styled ad-hoc

### Technical Debt

| Debt Item | Severity | File |
|-----------|----------|------|
| `ReportChatModal.tsx` is dead code — never rendered anywhere | **High** | `components/ReportChatModal.tsx` |
| No shared `<Input>` component — styling duplicated across every form field | **High** | Multiple files |
| No shared `<Select>` component — raw `<select>` styled inline everywhere | **High** | `BookingWorkspace.tsx`, `Login.tsx` |
| `updateAppointmentStatus` API endpoint exists but is never called in the UI | **Medium** | `lib/api.ts` |
| `listMyAppointments` API endpoint exists but there is no patient-facing appointments view | **Medium** | `lib/api.ts` |
| `VITE_COGNITO_DOMAIN` in `.env.example` is defined but never used in the frontend | **Low** | `lib/cognito.ts` |
| Token stored in `localStorage` — vulnerable to XSS. `httpOnly` cookie would be safer | **Medium** | `lib/auth.ts` |
| JWT decoded client-side without signature verification | **Low** | `lib/auth.ts` — acceptable for frontend, just document it |
| No loading skeleton states — raw `"Loading reports…"` text only | **Medium** | All dashboard pages |
| Relationship field in patient profile is a raw text input ("e.g. Self") — should be a select | **Low** | `BookingWorkspace.tsx` |

---

## Complete Route Inventory

| Route | Purpose | User Type | Components | Quality Score | Recommendation |
|-------|---------|-----------|------------|---------------|----------------|
| `/login` | Authentication gateway | Anonymous | Login, Card, Button | 6/10 | REDESIGN — needs brand presence, forgot-password link |
| `/` | Patient home: book tests + view reports | Patient | PatientDashboard, BookingWorkspace, BentoCard, ReportPreviewModal | 4/10 | SPLIT — booking and reports deserve separate pages |
| `/staff` | Staff ops queue + upload | Staff | StaffDashboard, BentoCard, Button, (Upload icon) | 4/10 | REDESIGN — needs filters, search, date nav, status management |

### Missing Routes That Block Launch

| Route | Purpose | Priority |
|-------|---------|----------|
| `/book` | Dedicated booking wizard | Critical |
| `/reports` | Patient reports list with filters | Critical |
| `/reports/:id` | Individual report page (vs modal) | High |
| `/appointments` | Patient appointment history | High |
| `/account` | Profile, password change | High |
| `/forgot-password` | Password reset | **Critical** |
| `/staff/patients` | Patient lookup for staff | Medium |
| `/staff/reports` | Staff report management view | Medium |

---

## Screen Inventory

---

### Screen: Login (`/login`)

#### Purpose
Entry point for all users. Authenticates via email + password against AWS Cognito. Redirects to role-appropriate dashboard.

#### Key User Actions
- Enter email
- Enter password
- Submit form
- See error message if credentials fail

#### Components Used
- Card, CardHeader, CardTitle, CardContent
- Button
- Raw `<input>` elements

#### Problems

1. **No branding beyond the word "LabLumen"** — No logo, no tagline, no visual identity. A new patient lands here and sees a generic card.
2. **No "Forgot Password" link** — Hard blocker for launch. Users will forget passwords.
3. **No registration / sign-up link** — How do new patients create accounts? The app has no self-registration UI. This implies admin-created accounts only, which is a significant UX limitation.
4. **Password field has no show/hide toggle** — Basic usability gap.
5. **Error messages are generic** — "Sign-in failed" (when Cognito throws its own errors like "User does not exist" or "Incorrect username or password") — these could be surfaced directly.
6. **No loading indicator beyond button disabled state** — The button says "Signing in…" which is fine, but there is no spinner or progress indication.
7. **`bg-surface` background** — A flat off-white background for the login screen is bland. Login pages are brand moments.

#### Recommended Redesign

Split-panel login: left panel with brand hero (product screenshot, tagline, trust signals like "HIPAA-ready", "AI-powered"), right panel with auth form. Add forgot-password link. Add logo. Add show/hide password toggle.

---

### Screen: Patient Dashboard (`/`)

#### Purpose
The patient's home screen. Currently does everything: book tests AND display all reports.

#### Key User Actions
- Select or create a patient profile
- Choose lab tests
- Select date and time slot
- Book appointment
- View report list
- Open report preview modal
- Download PDF
- Chat with AI about report

#### Components Used
- PatientDashboard (route)
- BentoCard × 2 ("Book a Lab Test", "My Reports")
- BookingWorkspace (embedded booking form)
- ReportPreviewModal (full modal)
- Button

#### Problems

1. **Two unrelated primary flows on one page** — Booking a test and reviewing reports are cognitively distinct tasks. They do not belong on the same screen. A patient who just received results and wants to read them does not want to see the booking form. A patient trying to book does not want to scroll past their report history.
2. **The booking form has no visual step progression** — There is no indication of where the user is in the booking flow. Profile → Tests → Date/Time → Confirm is a 4-step process that appears as a flat vertical form.
3. **No confirmation step before booking** — The user clicks "Book appointment" and it immediately fires. For a healthcare appointment, there should be a review screen: "You're booking a CBC and Lipid Panel on June 20 at 10:00 AM for $85. Confirm?"
4. **"Add profile" for additional family members is hidden** — Only appears inline, in a collapsed state. This is a critical feature (booking for children/dependents) with terrible discoverability.
5. **Report list is a plain `<ul>` with `<li>` items** — No status badges, no test category icons, no date grouping, no filtering.
6. **Booking success feedback disappears on next render** — The `feedback` state is local to `BookingWorkspace` and does not persist if the user scrolls or the component re-renders.
7. **Time slots are hardcoded strings** — `["09:00", "09:30", ... "16:00"]` in the source code. These should be fetched from the API and reflect real availability.
8. **No appointment history for patients** — Once a patient books, they have no way to see their upcoming appointments, cancel, or reschedule. The `listMyAppointments` API exists but is never called.
9. **No onboarding for first-time users** — A new patient who has never created a profile sees "No patient profiles yet — add one to start booking." with a small inline button. This is weak guidance.
10. **Empty state for reports is text-only** — "No reports yet. Once a lab uploads your results, they appear here." No illustration, no CTA, no estimated timeline.

#### Recommended Redesign

**Separate into three pages:**
1. `/` — Patient home with navigation links and a summary widget (upcoming appointment, newest report status)
2. `/book` — Dedicated multi-step booking wizard with visual calendar and step indicator
3. `/reports` — Report list with filters (date, test type, status) and direct links to individual report pages

---

### Screen: Report Preview Modal

#### Purpose
The primary report consumption experience. A full-screen modal with the PDF on the left (70%) and an AI summary + chat panel on the right (30%).

#### Key User Actions
- Read AI summary
- Download PDF
- View PDF inline via iframe
- Switch to chat panel
- Ask natural language questions about results
- Navigate back to summary

#### Components Used
- ReportPreviewModal (standalone component)
- react-markdown (AI content rendering)
- Button, lucide icons (Download, X, ArrowLeft, MessageCircle, Send)

#### Problems

1. **Completely broken on mobile** — `w-[70%]` and `w-[30%]` are fixed percentage widths with no responsive breakpoint. On a 375px screen this renders as two unusably narrow columns.
2. **The iframe PDF viewer is dependent on browser PDF support** — Safari on iOS often blocks or degrades iframe PDF rendering. No fallback.
3. **The FAB (floating action button) for chat overlaps the summary content** — The chat button (`absolute bottom-5 right-5`) covers the last lines of the summary when the content is short.
4. **No keyboard shortcut to close modal** — Escape key is not handled. Users expect `Escape` to close modals.
5. **The "thinking…" indicator is a plain italic text line** — Animated dots or a proper loading indicator would be more professional.
6. **No way to start a new conversation** — The chat history persists for the session but there is no "clear" or "start over" button.
7. **The disclaimer ("For general understanding only — not medical advice") is correct but visually weak** — It sits below the input at small text in muted color. For a health product, this needs to be more prominent, especially on first chat open.
8. **The 30% panel is too narrow for comfortable reading** — At max-width-6xl (1152px), 30% = ~345px. This is cramped for markdown-rendered AI responses, especially with code-like values like "Hemoglobin: 14.2 g/dL (Normal: 13.5–17.5 g/dL)".
9. **No copy-to-clipboard on AI responses** — Users will want to share summaries with family or other doctors.
10. **The panel is always a modal** — There is no deep-link to a specific report. Sharing a report URL is impossible.

#### Recommended Redesign

- Create a `/reports/:id` dedicated page (not modal) with responsive layout
- Mobile: tabs (Summary | PDF | Chat)
- Desktop: sidebar layout (left: PDF iframe, right: resizable summary/chat panel)
- Add Escape key handler and proper focus trap
- Add copy-to-clipboard on AI summary
- Add prominent, well-designed disclaimer banner on first chat message

---

### Screen: Staff Dashboard (`/staff`)

#### Purpose
Operational hub for lab staff. Shows today's volume, pending upload count, total orders, and a full operations queue table for uploading PDFs.

#### Key User Actions
- View today's scheduled appointments
- View pending uploads count
- Scroll through the ops queue
- Upload a PDF for a specific order

#### Components Used
- StaffDashboard (route)
- OpsRowItem (sub-component, inline)
- BentoCard × 4
- Button, Upload icon
- Raw `<table>`, `<tr>`, `<td>`

#### Problems

1. **No date filtering on the queue** — The table shows all orders ever, not just today's. A lab handling 100+ orders per day cannot work with this. There is no way to filter by date, patient, test type, or status.
2. **No search** — Cannot search for a patient by name.
3. **The 3 stat cards are the entirety of the dashboard analytics** — "Today's Scheduled Volume", "Pending PDF Uploads", "Total Orders". There is no trend, no history, no completion rate.
4. **No appointment status management** — The `updateAppointmentStatus` API endpoint exists but is never wired to any UI. Staff cannot mark appointments as completed, in-progress, no-show, or cancelled.
5. **Upload is a hidden file input triggered by a button** — This works but is a weak pattern for a file-heavy workflow. There is no drag-and-drop.
6. **No upload progress indicator** — Large PDFs take time. The button shows "Uploading…" but there is no progress bar.
7. **Upload success/failure messages are per-row inline text** — Small, easily missed, and they do not persist across re-renders.
8. **"Report uploaded" is the only terminal state** — There is no way to know if AI processing succeeded, failed, or is pending from the staff view.
9. **No sorting on the table** — Cannot sort by patient name, date, test, or upload status.
10. **The OpsRowItem component is defined inline in StaffDashboard.tsx** — Should be extracted.
11. **No pagination** — The table renders all rows. At scale this will be a performance and UX problem.
12. **"Total Orders" stat counts all time orders, not a meaningful metric** — Replace with: "Completed Today", "AI Processing", "Failed".

#### Recommended Redesign

- Add date picker at the top defaulting to today
- Add patient search input
- Add status filter tabs (All | Pending Upload | Processing | Completed | Failed)
- Add sortable column headers
- Replace inline file input with a proper upload zone (drag-and-drop + click)
- Replace 3 stat cards with 5 meaningful metrics: Scheduled Today, Completed Today, Pending Upload, AI Processing, Failed AI

---

## Current User Journey Audit

### Anonymous Visitor

**Entry Point:** Direct URL navigation (no public landing page exists)

| Step | Experience | Friction |
|------|-----------|---------|
| Visit `lablumen.com` | Redirected to `/login` via ProtectedRoute | Cannot preview the product |
| See login page | Generic card, no brand | No value proposition communicated |
| No account? | Dead end — no self-registration | **Critical blocker** |

**Verdict:** There is no public experience. A visitor who does not already have credentials sees a login form and nothing else. This is a closed-access product by default.

**Missing:** Landing page, self-registration, or at minimum a "request access" flow.

---

### Patient Journey

#### First Login

| Step | Experience | Problems |
|------|-----------|---------|
| Navigate to `/login` | Generic login card | No brand, no reassurance |
| Enter credentials | Email + password form | No show/hide password, no forgot-password |
| Submit | Loading state, then redirect | Smooth |
| Land on Patient Dashboard | Two BentoCards: booking + reports | Cognitive overload — two different tasks presented equally |

#### Booking a Lab Test

| Step | Experience | Problems |
|------|-----------|---------|
| See "Book a Lab Test" card | Entire form visible immediately | No step progression, overwhelming |
| First-time: no patient profile | Inline text with "Add profile" button | Weak onboarding, buried CTA |
| Create patient profile | 6-field inline form appears | Grid layout, no field labels in grid mode — just placeholders |
| Select tests | Checkbox grid with prices | Good pattern, but no test descriptions visible, no categories |
| Select date | Native date input | No calendar widget — no availability indication |
| Select time | Dropdown of hardcoded slots | No indication of real availability |
| Click "Book appointment" | Immediate API call | No confirmation screen |
| Success | Inline green text message | Message disappears on re-render; no email confirmation visible in UI |

**Unnecessary steps:** Profile creation should be part of a separate onboarding flow, not inline in the booking form  
**Missing:** Appointment confirmation screen, email notification confirmation, ability to view or cancel the booking

#### Viewing Reports

| Step | Experience | Problems |
|------|-----------|---------|
| See "My Reports" card | Plain list with status text | No icons, no categories, no date grouping |
| Click "View Report" | Full-screen modal opens | Good entry point |
| See PDF + AI summary | 70/30 split | Excellent concept, execution has gaps |
| Read AI summary | Markdown-rendered text | Good |
| Click chat FAB | Panel slides to chat | Good pattern, but FAB covers content |
| Ask question | Response appears | Good |
| Return to summary | Back arrow | OK but destroys chat session |

---

### Staff Journey

#### Login

Same as patient — generic, no role-specific login experience.

#### Daily Ops Workflow

| Step | Experience | Problems |
|------|-----------|---------|
| Land on `/staff` | 3 stat cards + ops table | Stat cards are too sparse; table shows all-time data |
| Find today's appointments | Scan table visually | No date filter; must scroll through all rows |
| Find pending uploads | Scan "Pending PDF Uploads" stat | Number only; must find rows manually |
| Upload PDF | Click "Upload PDF" button | File picker opens; no drag-and-drop |
| Upload progress | Button shows "Uploading…" | No progress, no size indicator |
| Upload success | Small green text in row | Easily missed |
| Check AI processing status | Cannot | Not visible in staff dashboard |

**Confusing steps:** There is no way for staff to know if the AI successfully processed the report. They upload, see "Report uploaded", and have no visibility into what happens next.

**Missing flows:** Appointment status management, patient lookup, report reprocessing on AI failure, bulk upload.

---

## Information Architecture Audit

### Current Structure

```
LabLumen
├── /login            (public)
└── [Protected]
    ├── /             (Patient)
    │   ├── Book a Lab Test      [section]
    │   └── My Reports           [section]
    └── /staff        (Staff)
        ├── Stat cards           [section]
        └── Operations Queue     [section]
```

### Problems

1. **Flat to the point of meaninglessness** — The app has two pages (excluding login). That is not information architecture; it is a prototype.
2. **Both roles land on pages that attempt too much** — The patient dashboard conflates booking (task) with report review (task). These are different mental modes.
3. **No navigation within a role** — Once logged in, a patient has one destination. A staff member has one destination. There are no sub-sections to navigate to.
4. **Critical features are hidden in modals** — The most valuable experience in the product (AI report chat) is hidden behind: "View Report" → modal → FAB → chat panel. Three clicks to reach the core differentiator, with no discoverability.
5. **Family member management has no home** — "Add profile" for dependents is an inline toggle in the booking form. It should be an account section.
6. **No settings, account, notifications, or help** — The only way to "manage your account" is to sign out.

### What Linear, Stripe, or Notion Would Redesign

**Linear** would insist on a persistent left-sidebar navigation with clear section labels (Dashboard, Appointments, Reports, Account). Every entity type (reports, appointments, tests) would have its own page with filtering, sorting, and bulk actions. No major workflow would be buried in a modal.

**Stripe** would create a patient home dashboard that shows a financial-style summary card (next appointment, recent report, action needed), then separate list views for each entity type. Status would be everywhere — every row, every card.

**Notion** would create a report workspace that combines the PDF, the AI summary, and the chat into a single scrollable page view — not a cramped modal. It would prioritize the reading experience as the primary interaction surface.

---

## Visual Design Audit

### Typography

**Score: 5/10**

- Uses Tailwind's default system font stack — no custom typeface
- Functional but not distinctive for a healthcare brand
- Type scale is consistent (`text-sm`, `text-xs`, `text-base`) but limited
- `text-2xl font-bold` for the LabLumen logo in login — appropriate
- No heading hierarchy beyond `text-sm font-semibold` (BentoCard titles) and body text
- `prose prose-sm` for AI markdown — correct choice

**Issues:**
- System font stack is 2018 SaaS default. Healthcare and AI products in 2026 use Inter, Geist, or DM Sans
- No display type for dashboard hero sections
- No consistent use of `font-semibold` vs `font-medium` hierarchy

---

### Spacing

**Score: 6/10**

- Consistent use of `space-y-4`, `gap-4` patterns
- `p-5 pb-2` / `p-5 pt-2` in card components is intentional and consistent
- Main layout uses `py-6 px-4` with `max-w-6xl` constraint — appropriate
- `rounded-bento` (16px) is applied consistently

**Issues:**
- The BentoCard title/content split (`pb-2` header + `pt-2` content) creates irregular internal spacing depending on content height
- The 3-stat-card grid and the ops table have jarring visual weight difference

---

### Colors

**Score: 6.5/10**

| Token | Value | Usage | Assessment |
|-------|-------|-------|------------|
| `primary` | `#008080` (teal) | CTAs, active nav, logo | Distinctive, appropriate for healthcare |
| `surface` | `#F8FAFC` | Page bg, input bg | Clean |
| `success` | `#10B981` | "Ready" status, uploaded | Standard |
| `warning` | `#F59E0B` | "Processing" status, pending count | Appropriate |
| `danger` | `#EF4444` | Errors, failed status | Standard |
| `text-dark` | `#0F172A` | Primary text | Good contrast |
| `text-muted` | `#64748B` | Secondary text | **WCAG concern at small sizes** |

**Issues:**
- `#64748B` on `#FFFFFF` for 12px (`text-xs`) text fails WCAG AA (contrast ratio ~4.0, minimum 4.5 for normal text)
- No secondary brand color — everything is either teal or slate
- No dark mode token definitions
- `primary/10` and `success/10` as tinted backgrounds are used inconsistently (only in feedback messages and disclaimer)
- The teal primary (#008080) is CSS keyword `teal`, which feels slightly unpolished — a custom teal like `#0D9488` (Tailwind's `teal-600`) would be richer

---

### Layout Consistency

**Score: 5.5/10**

- BentoCard grid is consistent across both dashboards
- Header layout is consistent
- **Inconsistency**: The report modal uses a full-viewport overlay with fixed percentage widths — no relation to the grid system used elsewhere
- **Inconsistency**: The `max-w-6xl` container is used on all pages but the modal uses `max-w-6xl` without the outer container, leading to potential misalignment on very wide screens

---

### Visual Hierarchy

**Score: 4/10**

- Every BentoCard looks identical regardless of content importance
- The 3 stat cards on the staff dashboard are visually equal — no "primary" metric is emphasized
- The report list items (the most important content on the patient dashboard) look like plain text list items
- Nothing draws the eye. The design communicates everything equally, which means nothing is prioritized

---

### Empty States

**Score: 2/10**

All empty states are one or two lines of muted text:
- "No reports yet. Once a lab uploads your results, they appear here."
- "No orders yet. Once patients book tests, their orders appear here."
- "Loading reports…"

These are not empty states. They are placeholder text. A launch-ready product has illustrated empty states with a relevant icon, a clear headline, a brief explanation, and a call-to-action button. The reports empty state for a new patient should read: "Your results will appear here" with an illustration and "Book your first test →".

---

### Loading States

**Score: 2/10**

- `"Loading reports…"` — plain text
- `"Loading queue…"` — plain text

No skeleton screens. No spinner components. No animated placeholders. In 2026, users expect skeleton loaders that match the shape of the content they are about to see.

---

### Error States

**Score: 4/10**

- Form errors: `rounded-bento bg-danger/10 px-3 py-2 text-sm text-danger` — visually adequate
- API errors: displayed inline in small text — adequate but inconsistent (sometimes per-row, sometimes per-form)
- Global 401 handling: `window.location.href = "/login"` — functional but jarring. Users lose context.
- No retry mechanism exposed in the UI for failed data fetches

---

### Generic AI-Generated UI Patterns (Red Flags)

The following patterns suggest auto-generated or template UI rather than intentional product design:

1. The bento card grid as the entire page layout for every screen
2. The "Sign in to your account" CardTitle — this is the default placeholder text for auth forms
3. Flat list items with pill-style status text rather than proper status badges
4. The 70/30 fixed split in the modal (a common AI-generated layout that ignores responsive behavior)
5. Three stat cards in a row with giant numbers — this is a dashboard template pattern, not a designed experience

---

## Component Inventory

| Component | Reusability | Design Quality | Consistency | Redesign Rec |
|-----------|-------------|---------------|-------------|--------------|
| `Button` | **9/10** | 7/10 | 9/10 | Keep — add `destructive` and `loading` variants |
| `Card` / `CardHeader` / `CardContent` | **8/10** | 7/10 | 8/10 | Keep — add size variants |
| `BentoCard` | **7/10** | 6/10 | 8/10 | Keep but add optional `action` slot for header-right CTA |
| `Layout` | **6/10** | 5/10 | 7/10 | Redesign — nav needs expansion, mobile menu |
| `BookingWorkspace` | **3/10** | 4/10 | 5/10 | Decompose into multi-step wizard |
| `ReportPreviewModal` | **4/10** | 6/10 | 6/10 | Convert to page, fix mobile, extract panels |
| `ReportChatModal` | **N/A** | 5/10 | N/A | **Delete** — dead code, superseded by ReportPreviewModal |
| `OpsRowItem` (inline) | **3/10** | 5/10 | 5/10 | Extract to file, add drag-and-drop upload |
| `ProtectedRoute` | **8/10** | 8/10 | 8/10 | Keep |
| Raw `<input>` (various) | **1/10** | 4/10 | 3/10 | Extract to shared `Input` component |
| Raw `<select>` (various) | **1/10** | 4/10 | 3/10 | Extract to shared `Select` component |
| Raw `<label>` + field pattern | **2/10** | 5/10 | 4/10 | Extract to shared `FormField` wrapper |

### Missing Components That Block Launch

| Component | Where Needed | Priority |
|-----------|-------------|---------|
| `Input` (shared primitive) | Login, BookingWorkspace, chat input | Critical |
| `Select` (shared primitive) | BookingWorkspace (tests, slot, gender) | Critical |
| `Badge` (status indicator) | Report list, ops queue | High |
| `Skeleton` (loading placeholder) | All list views | High |
| `Toast` (transient feedback) | Booking success, upload success | High |
| `Dialog` (accessible modal primitive) | ReportPreviewModal | High |
| `Calendar` (date picker) | Booking date selection | High |
| `EmptyState` (illustrated) | Reports list, ops queue | Medium |
| `Spinner` | All loading states | Medium |
| `Tabs` | Staff queue status filter, mobile report view | Medium |

---

## Dashboard Audit

### Patient Dashboard

**First Impression:** Two cards stacked vertically. The page reads as "here is a form, here is a list." There is no sense of welcome, context, or priority.

**Information Density:** Under-dense at the top, over-dense in the booking form. The reports list could benefit from richer row content.

**Decision Support:** Weak. The patient cannot see: when their next appointment is, which reports are new since last visit, or which results need attention. A "CBC is flagged — please review" prompt would be high value.

**Navigation Effectiveness:** Non-existent within the page. Scroll to navigate.

**What belongs on the dashboard vs. separate pages:**

| Content | Current Location | Recommended |
|---------|-----------------|-------------|
| Full booking form | Dashboard card | `/book` — separate page |
| Complete report list | Dashboard card | `/reports` — separate page |
| Welcome + summary stats | Missing | Dashboard — add |
| Next appointment | Missing | Dashboard — add |
| "New report ready" alert | Missing | Dashboard — add |

---

### Staff Dashboard

**First Impression:** Three large numbers and a table. Functional but cold. No context about whether 12 pending uploads is good or bad compared to yesterday.

**Information Density:** Appropriately dense for an operations tool, but the data is wrong. "Total Orders: 47" is meaningless. "Completed today: 8/12" is meaningful.

**Decision Support:** None. The staff member must visually scan the table to identify what needs attention. The pending count tells them the number but not who or what.

**What belongs on dashboard vs. separate pages:**

| Content | Current Location | Recommended |
|---------|-----------------|-------------|
| All-time stats | Dashboard | Replace with today-focused metrics |
| Full ops queue | Dashboard | Keep, but add filters and date navigation |
| Patient lookup | Missing | Add to dashboard or nav |
| AI processing status | Missing | Add to queue table |
| Failed reports | Missing | Add status and retry action |

---

## Appointment Booking Audit

### User Effort Assessment

| Step | Clicks Required | Clarity | Mobile Usability |
|------|----------------|---------|-----------------|
| Find booking section | 0 (on dashboard) | Passive — it's just there | OK |
| Create patient profile (first-time) | 3 (see text, click button, fill form, save) | Confusing — inline expand | Poor |
| Select tests | 1 per test | Good — checkbox labels with prices | OK |
| Select date | 1 | Poor — native date input, no calendar | Poor |
| Select time slot | 1 | Adequate | OK |
| Submit booking | 1 | Good — disabled until valid | OK |
| Confirm booking | 0 | **Missing** — no confirmation step | — |

**Total clicks for a first-time booking: ~8–10**
**Target for a well-designed experience: 4–6**

### Comparison Against Benchmarks

| Feature | LabLumen | Calendly | Airbnb | Modern Healthcare Portal |
|---------|---------|---------|--------|------------------------|
| Visual calendar | No — native date input | Yes — interactive calendar widget | Yes | Yes |
| Real-time availability | No — all slots show always | Yes | Yes | Yes |
| Step indicator | No | Yes (3-step wizard) | Yes (sidebar progress) | Yes |
| Confirmation screen | No | Yes | Yes — full review screen | Yes |
| Email confirmation visible | Implied | Yes | Yes | Yes |
| Mobile experience | Poor | Excellent | Excellent | Good |
| Test/service descriptions | Name + price only | Full description | Full listing | Yes |

### Specific Redesign Recommendation

Replace `BookingWorkspace` with a `/book` page featuring:

1. **Step 1 — Who is this for?** Patient selector or "Add new person" — full page, not inline form
2. **Step 2 — Choose tests** — Card grid with test name, description, price, category badge
3. **Step 3 — Pick a date and time** — Full calendar widget, only future dates enabled, slots fetched from API
4. **Step 4 — Review and confirm** — Summary of who, what, when, total price, confirm CTA
5. **Confirmation** — Full-page success state with appointment details, calendar add link, "Return to dashboard"

---

## Reports Experience Audit

### Report Discovery

The patient must scroll past the booking form to find their reports. There is no notification that a new report is ready. The only indication is the polling-based update to the report list — which is silent.

**Problems:**
- No "new" badge or highlight for recently added reports
- No sort or filter (newest first is assumed but not guaranteed)
- No search by test name
- No status filter (Ready / Processing / Failed)

### Report Viewing

The modal approach is conceptually sound — stay in context, see report immediately. The execution has problems (mobile, focus management, panel width).

### PDF Experience

- Browser's built-in PDF renderer via `<iframe>` — no annotation, no zoom controls custom to the app, degraded on iOS Safari
- `aria-label="Report PDF"` on iframe is good
- No fallback for failed PDF load beyond red text "Could not load PDF"
- No option to open PDF in new tab (Download is available but opens a download, not a tab)

### AI Summary

This is the product's core differentiator and it is good:
- Markdown rendering is correct
- The summary panel is readable (on desktop)
- Processing states are handled (ready / failed / still processing)

**Gaps:**
- No way to copy the summary
- No timestamp ("Summary generated 2 hours ago")
- No explanation of what the AI is and is not (first-time patient has no context)

### Report Chat

The chat experience is solid for an MVP. Key missing elements:
- No suggested follow-up questions (starter prompts like "Is my hemoglobin normal?" or "What should I eat?")
- No chat history persistence between sessions
- Disclaimer is correct but visually weak
- No typing indicator with animation (just plain "Thinking…" text)

### Recommended Workspace Layout

Convert to a `/reports/:id` page with this layout:

```
┌─────────────────────────────────────────────────────────┐
│ ← Back to Reports    [Report Name]      [Download PDF]  │
├─────────────────────┬───────────────────────────────────┤
│                     │  [Summary]  [Chat]  [Details]     │
│                     ├───────────────────────────────────┤
│   PDF VIEWER        │                                   │
│                     │  AI Summary content               │
│   (resizable)       │  or                               │
│                     │  Chat interface                   │
│                     │                                   │
│                     │  [Copy Summary]                   │
└─────────────────────┴───────────────────────────────────┘
```

---

## AI Experience Audit

### Discoverability

**Score: 3/10**

The AI features (summary + chat) are buried: a patient must open the report modal, read the summary, and then notice a floating circular button. There is no onboarding to explain that AI capabilities exist. The word "AI" does not appear in the UI — only in the section label "AI Summary".

### User Trust

**Score: 5/10**

- The disclaimer exists ("For general understanding only — not medical advice")
- But it only appears in the chat panel, not when viewing the AI summary
- No explanation of the AI (what model, what data it has access to, privacy)
- No confidence indicator on AI responses
- No source citations (e.g., "Based on your CBC values: Hemoglobin: 14.2…")

### Interaction Design

**Score: 5/10**

- The chat UI is functional and familiar
- Markdown rendering in responses is correct and looks good
- Message bubbles are appropriately styled (primary blue for user, white for assistant)
- "Thinking…" indicator exists
- **Missing**: Animated typing indicator, message timestamps, copy button, suggested starters, error retry

### Information Presentation

**Score: 6/10**

- Markdown rendering handles headers, bullets, and emphasis correctly
- The `prose prose-sm` class handles typography well
- **Missing**: Lab value highlighting (flag abnormal values in red/amber), reference range display, trend charts

### Comparison Against AI Benchmarks

| Feature | LabLumen | ChatGPT | Notion AI | Perplexity | Cursor |
|---------|---------|---------|-----------|------------|--------|
| Suggested starters | No | Yes | Yes | Yes | Yes |
| Animated typing | No | Yes | Yes | Yes | Yes |
| Source citations | No | Yes (with browsing) | No | **Yes** | Yes |
| Copy response | No | Yes | Yes | Yes | Yes |
| Regenerate response | No | Yes | Yes | Yes | No |
| Conversation persistence | Session only | Persistent | Persistent | Session | Session |
| Contextual awareness | Yes (report data) | Generic | Yes | Yes | Yes |

---

## Mobile Experience Audit

### Responsiveness

| Screen | Mobile Score | Primary Problem |
|--------|-------------|----------------|
| Login | 7/10 | Acceptable — full-width card |
| Patient Dashboard | 5/10 | Booking form 2-col grid breaks at narrow widths |
| Report Preview Modal | **1/10** | Fixed 70/30 split — completely broken |
| Staff Dashboard | 5/10 | Ops table requires horizontal scroll — functional but not ideal |

### Touch Targets

- Buttons use `h-10 px-4` (default) and `h-9 px-3` (sm) — the sm size (36px height) is below the recommended 44px minimum touch target
- The chat FAB is `h-12 w-12` (48px) — acceptable
- Table row upload button `size="sm"` is below recommended size

### Mobile Navigation

The navigation bar is a single horizontal bar with text links. On mobile:
- The email address (`claims?.email`) is hidden with `hidden sm:inline` — correct
- But on a 375px screen, "Patient | Sign out" fits but a future navigation expansion will overflow
- No hamburger menu or mobile drawer exists

### Forms on Mobile

- The `grid-cols-2` in the profile form creates two narrow columns on mobile — uncomfortable
- Native date inputs have inconsistent UX across iOS/Android
- The test selection `grid-cols-1 gap-2 sm:grid-cols-2` is correctly responsive

### Mobile Blockers for Launch

1. **Report modal is unusable on mobile** — Critical
2. **No mobile navigation pattern** — High
3. **Profile form 2-col grid** — Medium
4. **Small touch targets** — Medium
5. **No native mobile interactions** (swipe to dismiss, haptic feedback) — Low

---

## Accessibility Audit

### Keyboard Navigation

- Form inputs are native HTML — keyboard navigable by default ✓
- Buttons use `<button>` elements — keyboard activatable ✓
- Modal does not trap focus — user can Tab out of the modal to background content ✗
- No `Escape` key handler to close modals ✗
- No skip-to-content link ✗
- The chat FAB has `aria-label="Open chat"` ✓
- The back button in chat has `aria-label="Back to summary"` ✓
- The close button has `aria-label="Close"` ✓
- The send button has `aria-label="Send"` ✓

### Focus States

- `focus-visible:ring-2 focus-visible:ring-primary` is applied to the Button component ✓
- Raw `<input>` elements use `focus:border-primary focus:outline-none` — removes the default browser outline without a replacement that works for keyboard users ✗
- The chat FAB uses `focus:outline-none focus:ring-2 focus:ring-primary/50` ✓

### Color Contrast

| Element | Foreground | Background | Ratio | WCAG AA |
|---------|-----------|-----------|-------|---------|
| Body text | `#0F172A` | `#FFFFFF` | ~19:1 | ✓ Pass |
| Muted text `text-sm` | `#64748B` | `#FFFFFF` | ~4.1:1 | ✓ Pass |
| Muted text `text-xs` | `#64748B` | `#FFFFFF` | ~4.1:1 | ✗ **Fail** (need 4.5) |
| Button label | `#FFFFFF` | `#008080` | ~4.5:1 | ✓ Borderline pass |
| Success text | `#10B981` | `#FFFFFF` | ~2.9:1 | ✗ **Fail** |
| Warning text | `#F59E0B` | `#FFFFFF` | ~2.8:1 | ✗ **Fail** |
| Danger text | `#EF4444` | `#FFFFFF` | ~3.9:1 | ✗ **Fail** (need 4.5) |

**Three semantic colors (success, warning, danger) fail WCAG AA contrast.** These are used for status labels throughout the app.

### Screen Reader Compatibility

- The modal has `role="dialog"` and `aria-modal="true"` ✓
- No `aria-labelledby` connecting the modal to its title ✗
- Report list items have no role or ARIA description ✗
- Stat cards have no ARIA labels (`<p>47</p>` inside a card with title "Total Orders" — the number is not associated with its label programmatically) ✗
- Loading states have no `aria-live` regions — screen readers do not announce when content loads ✗
- The feedback messages (booking success/error) have no `aria-live` regions ✗

### Accessibility Improvements Required for Launch

1. Add focus trap to all modals (focus-trap-react or custom)
2. Add `Escape` key handler to modals
3. Fix color contrast for success (#10B981), warning (#F59E0B), danger (#EF4444) on white
4. Add `aria-live="polite"` to loading and feedback regions
5. Add `aria-labelledby` to modal dialogs
6. Add skip-to-content link
7. Replace `focus:outline-none` with proper focus ring on raw inputs
8. Associate stat card numbers with their labels via `aria-describedby`

---

## Modern SaaS Benchmark Comparison

| Feature | LabLumen | Linear | Stripe | Notion | Vercel | Airbnb | Calendly |
|---------|---------|--------|--------|--------|--------|--------|---------|
| Navigation depth | 1 level | 3+ levels | 4+ levels | Sidebar + pages | Sidebar | Full nav | Wizard |
| Empty states | Text only | Illustrated + CTA | Illustrated + CTA | Illustrated + CTA | Illustrated | Illustrated | Illustrated |
| Loading states | Text | Skeleton | Skeleton | Shimmer | Skeleton | Skeleton | Spinner |
| Mobile | Poor | Good | Excellent | Good | Good | Excellent | Excellent |
| Onboarding | None | Interactive tour | Guided setup | Template gallery | Project wizard | None needed | None needed |
| Keyboard shortcuts | None | Extensive | Moderate | Extensive | Moderate | None | None |
| Dark mode | No | Yes | No | Yes | Yes | No | No |
| Search | None | Command palette | None | Global search | None | None | None |
| Notifications | None | Yes | Yes | Yes | Yes | Yes | Yes |
| Analytics/Charts | None | Yes | Yes | No | Basic | No | Basic |

**Specific Gaps:**
- **vs. Linear**: No keyboard shortcuts, no command palette, no sidebar navigation, no inline actions
- **vs. Stripe**: No detailed status tracking, no event timeline, no audit log visibility
- **vs. Notion**: No persistent state for AI interactions, no block-based content, no sharing
- **vs. Vercel**: No real-time status updates (SSE/WebSocket), no deployment-style timeline for report processing
- **vs. Airbnb**: Booking flow is far inferior — no calendar widget, no availability visualization, no price breakdown
- **vs. Calendly**: The booking experience is 3 generations behind — Calendly has a polished multi-step wizard, timezone handling, and confirmation screens

---

## Design System Audit

### Does a Design System Exist?

**Partially.** There is a design token file (`tokens.ts`) and Tailwind configuration, but no component documentation, no Storybook, and no formal design system. What exists is a good foundation.

### Color Tokens

Defined and consistent. **Gaps:**
- No shade scale (no `primary-100` through `primary-900` — only one primary value)
- No secondary color
- No surface elevation levels beyond `background` and `surface`

### Typography Scale

Not explicitly defined. Uses Tailwind's default scale (`text-xs`, `text-sm`, `text-base`, `text-2xl`). **Gaps:**
- No custom font defined
- No display/heading levels
- No line-height tokens

### Spacing System

Uses Tailwind's default 4px grid. Consistent use throughout. This is fine.

### Border Radius System

Only `rounded-bento` (16px) exists. This is applied everywhere uniformly. **Gap**: No smaller radius option for chips, badges, or inline elements.

### Elevation System

Only `shadow-bento-diffused` exists. **Gap**: No elevation hierarchy (cards, modals, dropdowns, tooltips all need different elevations). The modal uses the same shadow as cards.

### Inconsistencies

1. Buttons use `rounded-bento` (16px) — this is large for small buttons
2. Raw inputs use `rounded-bento` — visually consistent but an unusually large radius for text inputs
3. The report modal uses `max-w-6xl` without the page container — margin inconsistency vs. other pages
4. Card border is `border-slate-100` but form inputs use `border-slate-200` — two different grey scales used in adjacent elements

---

## Frontend Technical Debt (Ranked by Severity)

| # | Issue | Severity | Files |
|---|-------|----------|-------|
| 1 | `ReportChatModal.tsx` is dead code — defined, never imported or rendered | Critical | `components/ReportChatModal.tsx` |
| 2 | No shared `<Input>` primitive — 10+ raw `<input>` elements styled inline | High | `BookingWorkspace.tsx`, `Login.tsx`, `ReportPreviewModal.tsx`, `ReportChatModal.tsx` |
| 3 | Report modal has no responsive breakpoints — broken on mobile | High | `components/ReportPreviewModal.tsx` |
| 4 | No modal focus trap or Escape handler | High | `components/ReportPreviewModal.tsx`, `components/ReportChatModal.tsx` |
| 5 | Semantic color tokens (success, warning, danger) fail WCAG AA on white | High | `tailwind.config.ts` |
| 6 | Time slots hardcoded in source (`TIME_SLOTS` array) — not from API | High | `components/BookingWorkspace.tsx` |
| 7 | `updateAppointmentStatus` API method is defined but never called | Medium | `lib/api.ts` |
| 8 | `listMyAppointments` API method is defined but there is no patient appointments page | Medium | `lib/api.ts` |
| 9 | No loading skeleton states — plain text only | Medium | `routes/PatientDashboard.tsx`, `routes/StaffDashboard.tsx` |
| 10 | `BookingWorkspace` has 7 useState calls in one component — needs decomposition | Medium | `components/BookingWorkspace.tsx` |
| 11 | No `<Select>` primitive — raw `<select>` elements styled inline | Medium | `BookingWorkspace.tsx` |
| 12 | JWT stored in localStorage (XSS-vulnerable) | Medium | `lib/auth.ts` |
| 13 | No `aria-live` regions for loading/feedback states | Medium | All pages |
| 14 | `OpsRowItem` defined inline in `StaffDashboard.tsx` | Low | `routes/StaffDashboard.tsx` |
| 15 | `VITE_COGNITO_DOMAIN` env var defined in `.env.example` but unused | Low | `lib/cognito.ts` |

---

## Redesign Opportunities

### High Impact / Low Effort

| Opportunity | UX Gain | Complexity |
|-------------|---------|-----------|
| Add `Escape` key handler to both modals | Removes accessibility blocker | 1 hour |
| Add focus trap to modals | Removes accessibility blocker | 2 hours (use `focus-trap-react`) |
| Delete `ReportChatModal.tsx` (dead code) | Removes confusion and bundle weight | 15 minutes |
| Extract `<Input>` and `<Select>` primitives | Consistency, maintainability | 2 hours |
| Fix semantic color contrast (use `#059669` for success, `#D97706` for warning, `#DC2626` for danger) | WCAG AA compliance | 30 minutes |
| Add skeleton loading states | Perceived performance | 3 hours |
| Add `aria-live="polite"` to feedback regions | Screen reader accessibility | 1 hour |
| Add "Forgot password?" link to login | Launch blocker removal | 2 hours (needs backend route) |
| Hardcode removal: fetch time slots from API | Correctness | 4 hours |
| Add suggested starter questions to chat empty state | Discoverability, engagement | 2 hours |
| Add copy-to-clipboard to AI summary | User utility | 1 hour |
| Add status badges (Badge component) to report list | Clarity | 3 hours |

### High Impact / Medium Effort

| Opportunity | UX Gain | Complexity |
|-------------|---------|-----------|
| Fix report modal mobile responsiveness (tabbed layout < 768px) | Removes mobile blocker | 1 day |
| Extract `OpsRowItem` and add date filter + search to staff queue | Staff productivity | 1–2 days |
| Add empty state illustrations to all empty views | Perceived quality | 1 day |
| Add booking confirmation step | Reduces accidental bookings, adds trust | 1 day |
| Add patient appointments page (`/appointments`) | Critical missing feature | 1–2 days |
| Add Toast notifications for async actions | Professional polish | 1 day |
| Add report status filter + sort to patient report list | Usability | 1 day |
| Add appointment history to staff queue | Completeness | 1 day |

### High Impact / High Effort

| Opportunity | UX Gain | Complexity |
|-------------|---------|-----------|
| Redesign booking as `/book` multi-step wizard with calendar widget | Dramatically better conversion | 3–5 days |
| Convert report modal to `/reports/:id` page with responsive layout | Core experience, mobile, shareability | 3–4 days |
| Build staff queue with filters, search, pagination, drag-and-drop upload | Staff productivity, scale | 4–6 days |
| Add patient home dashboard with summary widgets | Product feel, decision support | 2–3 days |
| Implement persistent sidebar navigation (patient + staff) | Structure, navigation | 2–3 days |
| Add onboarding flow for new patients | Activation, retention | 3–4 days |
| Introduce custom font (Inter or Geist) + display type system | Brand, quality perception | 1–2 days |
| Add real-time processing status (WebSocket or SSE) | AI trust, transparency | 3–5 days |

---

## Future Information Architecture

### Recommended Navigation Model

**Patient (sidebar + header)**
```
Sidebar:
├── Home (dashboard summary)
├── Book a Test
├── My Reports
├── My Appointments
└── Account

Header: LabLumen logo | Notifications | Profile
```

**Staff (sidebar + header)**
```
Sidebar:
├── Today's Queue (default)
├── All Orders
├── Reports
└── (Account)

Header: LabLumen logo | Date picker | Notifications
```

### Proposed Sitemap

```
/                               → Redirect to /dashboard (patient) or /staff (staff)

[Public]
├── /login                      → Login page (with forgot-password link)
└── /forgot-password            → Password reset

[Patient — /app]
├── /app                        → Patient home dashboard
├── /app/book                   → Booking wizard (multi-step)
│   ├── step 1: who             → Patient profile select/create
│   ├── step 2: what            → Test selection with descriptions
│   ├── step 3: when            → Calendar + time slot
│   └── step 4: confirm         → Review + submit
├── /app/appointments           → Appointment history + upcoming
│   └── /app/appointments/:id  → Single appointment detail
├── /app/reports                → Report list with filters
│   └── /app/reports/:id       → Report workspace (PDF + AI + Chat)
└── /app/account                → Profile, password, notification settings

[Staff — /staff]
├── /staff                      → Operations queue (today, filtered)
├── /staff/orders               → All orders with advanced filters
├── /staff/reports              → Report management (upload, status)
└── /staff/patients             → Patient lookup

[Admin — /admin — future]
├── /admin/catalog              → Lab test management
├── /admin/users                → Staff user management
└── /admin/settings             → Clinic settings
```

---

## Screens To Preserve

| Screen / Component | Reason |
|-------------------|--------|
| `Layout.tsx` | Clean shell — header + outlet pattern is correct, just needs navigation expansion |
| `ProtectedRoute.tsx` | Well-implemented role-based auth guard |
| `Button` component | Well-structured CVA pattern, consistent, extensible |
| `Card` component | Good foundation, appropriate shadow and radius |
| `BentoCard` component | Correct abstraction, just needs richer prop API |
| `useReports` hook (polling logic) | The `refetchInterval` based on processing state is smart product logic — keep it |
| `lib/api.ts` | Well-structured API layer — typed, centralized, consistent error handling |
| `lib/auth.ts` + `lib/cognito.ts` | Auth flow is correct and clean |
| `lib/AuthContext.tsx` | Clean context pattern |
| AI chat interaction pattern | The concept of multi-turn chat with history passed to API is correct |
| AI summary + markdown rendering | The prose rendering is appropriate for the content type |

---

## Screens Requiring Complete Rewrite

| Screen / Component | Why |
|-------------------|-----|
| `ReportPreviewModal.tsx` | Needs to become a page (`/reports/:id`), not a modal. The 70/30 fixed split is broken on mobile. The component is doing too much (PDF loading, panel state, chat history, markdown rendering). Split into: `ReportPage`, `ReportPDFViewer`, `ReportSummaryPanel`, `ReportChatPanel`. |
| `ReportChatModal.tsx` | Dead code. Delete it. |
| `BookingWorkspace.tsx` | Needs to become a multi-step page (`/app/book`) with proper calendar, step indicator, and confirmation screen. The current implementation is a flat form with 7 state variables — not a booking experience. |
| `PatientDashboard.tsx` | Needs to split into three pages: patient home dashboard, booking wizard, reports list. The current single-page-does-everything model does not scale. |
| `StaffDashboard.tsx` | Needs filters, search, pagination, date navigation, sortable columns, drag-and-drop upload, and AI processing status. The current stat cards need to be replaced with meaningful operational metrics. |
| `Login.tsx` | Needs brand presence, forgot-password link, show/hide password, and properly designed error states. The current design communicates nothing about what LabLumen is. |

---

## Final Verdict

### 1. Can this frontend be modernized without touching backend APIs?

**Largely yes.** The backend API layer is already well-designed:
- The `/api/v1/appointments/ops` endpoint returns the data needed for filtered staff views
- The reports endpoints support the report page model
- The chat endpoint supports multi-turn conversation

The main additions needed are: a time-slot availability endpoint (currently hardcoded on the frontend), a forgot-password flow (requires Cognito integration), and potentially a notifications endpoint.

The routing restructure, mobile fixes, component extractions, accessibility improvements, and visual upgrades are all entirely frontend changes.

### 2. What percentage of the frontend should be redesigned?

**~70% should be redesigned or restructured.** Specifically:

| Category | % of Current Code | Recommendation |
|----------|------------------|----------------|
| Core logic (hooks, API, auth, QueryClient) | ~25% | Keep |
| Design tokens / Tailwind config | ~5% | Keep + extend |
| Button, Card primitives | ~5% | Keep + extend |
| Layout shell | ~5% | Keep + evolve |
| PatientDashboard | ~15% | Split into 3 pages |
| StaffDashboard | ~15% | Redesign with filters |
| ReportPreviewModal | ~15% | Rebuild as page |
| BookingWorkspace | ~10% | Rebuild as wizard |
| Login | ~5% | Redesign |

### 3. Recommended Redesign Roadmap

**Week 1 — Accessibility & Critical Bug Fixes**
- Fix report modal mobile responsiveness (tab layout on mobile)
- Add Escape key + focus trap to all modals
- Fix WCAG color contrast for success/warning/danger
- Add aria-live regions for loading and feedback
- Delete dead `ReportChatModal.tsx`
- Extract `Input`, `Select`, `Badge`, `Skeleton` primitives

**Week 2 — Navigation & Information Architecture**
- Add sidebar navigation (patient + staff)
- Create `/app/reports` list page with filters
- Create `/app/reports/:id` page (move modal to page)
- Create `/app/appointments` page
- Add `/forgot-password` flow

**Week 3 — Booking Wizard**
- Build `/app/book` multi-step wizard
- Integrate calendar date picker
- Fetch time slots from API (remove hardcoded slots)
- Add confirmation step
- Add booking success page

**Week 4 — Staff Dashboard Redesign**
- Add date filter, patient search, status filter tabs
- Add sortable table columns
- Add pagination
- Add drag-and-drop upload zone
- Wire up appointment status management (`updateAppointmentStatus`)
- Add AI processing status to ops table

**Week 5 — Polish & Onboarding**
- Add empty state illustrations
- Add Toast notifications
- Add skeleton loading screens
- Add patient home dashboard summary widgets
- Build first-run onboarding flow
- Add custom font (Inter or Geist)
- Write and run accessibility audit

**Week 6 — Launch Readiness**
- End-to-end test all patient and staff flows
- Cross-browser and cross-device testing
- Performance audit (Lighthouse)
- Security review (localStorage → httpOnly cookie consideration)
- Final WCAG AA compliance check

### 4. Expected Improvement in Perceived Product Quality

| Dimension | Current | Post-Roadmap | Expected Delta |
|-----------|---------|-------------|----------------|
| Overall product feel | 5/10 | 8.5/10 | +70% |
| Patient booking experience | 4/10 | 8/10 | +100% |
| Report/AI experience | 6/10 | 9/10 | +50% |
| Staff operations | 4/10 | 8/10 | +100% |
| Mobile experience | 3/10 | 8/10 | +167% |
| Accessibility | 3/10 | 8/10 | +167% |
| Brand impression | 4/10 | 8/10 | +100% |

**Bottom line:** LabLumen has excellent bones — solid engineering, a distinctive design language, a genuinely differentiated AI feature, and a real-world product problem worth solving. But it is currently a prototype dressed as a product. The gap between the current frontend and a launch-ready product is a well-scoped 6-week effort, not a full rewrite. The architectural decisions (React Query, Cognito, Tailwind tokens, TypeScript strict) are all correct and should not be changed. What is needed is more pages, better flows, mobile parity, and accessibility compliance. The AI report chat feature is the product's killer feature — it deserves to be front and center, not buried three clicks deep in a modal.
