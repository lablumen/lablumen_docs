# LabLumen Screen Inventory
**Complete Frontend Map — Redesign Reference**
*Generated: June 18, 2026 | Source: frontend/src/*

> This document is a complete map of the LabLumen frontend. It is intended to let a redesign be planned, specced, and delegated without reading the source code. Every route, layout, component, modal, hook, API call, and user flow is catalogued here.

---

## Table of Contents

1. [Route Map](#1-route-map)
2. [Layouts](#2-layouts)
3. [Pages](#3-pages)
4. [Component Groups](#4-component-groups)
5. [UI Primitives](#5-ui-primitives)
6. [Modals](#6-modals)
7. [Hooks](#7-hooks)
8. [API Layer](#8-api-layer)
9. [Auth System](#9-auth-system)
10. [User Flows](#10-user-flows)
11. [State Map](#11-state-map)
12. [Dead Code](#12-dead-code)

---

## 1. Route Map

### Complete Route Tree

```
/login                          [public]   → Login.tsx
/                               [patient]  → Layout.tsx > PatientDashboard.tsx
/staff                          [staff]    → Layout.tsx > StaffDashboard.tsx
```

### Route Configuration

**File:** `frontend/src/App.tsx`

```
createBrowserRouter([
  { path: "/login",  element: <Login /> },
  {
    element: <ProtectedRoute />,             ← auth gate (any logged-in user)
    children: [
      {
        element: <ProtectedRoute patientOnly />,    ← patient role gate
        children: [
          { path: "/", element: <Layout />, children: [{ index: true, element: <PatientDashboard /> }] }
        ]
      },
      {
        element: <ProtectedRoute staffOnly />,      ← staff role gate
        children: [
          { path: "/staff", element: <Layout />, children: [{ index: true, element: <StaffDashboard /> }] }
        ]
      }
    ]
  }
])
```

### Route Access Matrix

| Route | Anonymous | Patient | Staff | Staff (Admin) |
|-------|-----------|---------|-------|---------------|
| `/login` | ✓ | ✓ (redirects to `/`) | ✓ (redirects to `/staff`) | ✓ |
| `/` | ✗ → `/login` | ✓ | ✗ → `/login` | ✗ → `/login` |
| `/staff` | ✗ → `/login` | ✗ → `/login` | ✓ | ✓ |
| Any other path | ✗ → `/login` | ✗ → `/login` | ✗ → `/login` | ✗ → `/login` |

*Note: LAB_ADMIN group members access `/staff` — there is no admin-specific UI.*

### Missing Routes (Planned)

| Route | Purpose | Blocking? |
|-------|---------|-----------|
| `/forgot-password` | Password reset via Cognito | Yes — launch blocker |
| `/app/book` | Multi-step booking wizard | Yes — UX blocker |
| `/app/reports` | Patient report list | Yes — UX blocker |
| `/app/reports/:id` | Individual report workspace | Yes — mobile blocker |
| `/app/appointments` | Patient appointment history | High |
| `/app/account` | Patient profile & settings | High |
| `/staff/patients` | Patient lookup | Medium |
| `/staff/orders` | All orders with filters | Medium |
| `/staff/reports` | Report management | Medium |

---

## 2. Layouts

---

### Layout: `Layout.tsx`

**File:** `frontend/src/routes/Layout.tsx`
**Used by:** All protected routes (`/`, `/staff`)
**Recommendation:** KEEP — evolve to support sidebar navigation

#### Purpose

Provides the application shell: a fixed top header with logo and navigation, and a centered content area that renders child routes via `<Outlet />`.

#### Current Implementation

```
<div class="min-h-screen bg-surface">
  <header class="border-b bg-white">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between">
      <span>LabLumen</span>                    ← brand wordmark only, no logo
      <nav>
        <NavLink to="/">Patient</NavLink>       ← only shown to patients
        <NavLink to="/staff">Staff</NavLink>    ← only shown to staff
        <span>{claims.email}</span>             ← hidden on mobile (sm:hidden)
        <Button onClick={onLogout}>Sign out</Button>
      </nav>
    </div>
  </header>
  <main class="max-w-6xl mx-auto px-4 py-6">
    <Outlet />                                  ← child page renders here
  </main>
</div>
```

#### Dependencies

- `useAuth()` — reads `claims.email`, `isStaff` for conditional nav rendering
- `useNavigate()` — redirects to `/login` on logout
- `NavLink` — active state: `bg-primary text-white`, inactive: `text-text-muted hover:bg-surface`
- `Button` (ui/button)
- `LogOut` (lucide-react)

#### APIs Used

None. Auth state comes from Context.

#### Problems

1. No logo — wordmark "LabLumen" only in `text-lg font-semibold text-primary`
2. Nav items are just "Patient" and "Staff" — no descriptive labels (Dashboard, Reports, Appointments)
3. No mobile hamburger menu — nav items overflow horizontally on small screens
4. No notification bell, no account avatar, no profile dropdown
5. Single nav link per role means there is nowhere to navigate to within the app
6. The `max-w-6xl` container is hardcoded — at 1440px screens this leaves large dead margins

#### What To Keep

- The `<Outlet />` pattern and route nesting logic
- The `isStaff` conditional rendering for role-aware nav
- The auth-aware logout flow

#### Redesign Direction

Replace horizontal top-nav with a persistent left sidebar (240px) for both roles. Sidebar contains: logo, role-appropriate nav links, user avatar + email at bottom, sign out. Top header becomes a slim 48px bar for page title and global actions (notifications, search).

---

### Layout: `ProtectedRoute.tsx`

**File:** `frontend/src/routes/ProtectedRoute.tsx`
**Used by:** All routes except `/login`
**Recommendation:** KEEP — no changes needed

#### Purpose

Auth guard component with three operating modes:
1. Base (no props) — redirects unauthenticated users to `/login`
2. `patientOnly` — redirects staff away from patient routes
3. `staffOnly` — redirects patients away from staff routes

#### Current Implementation

```typescript
// Props: { patientOnly?: boolean; staffOnly?: boolean }
// Reads claims from useAuth()
// If no claims → <Navigate to="/login" replace />
// If patientOnly && isStaff → <Navigate to="/staff" replace />
// If staffOnly && !isStaff → <Navigate to="/" replace />
// Otherwise → <Outlet />
```

#### Dependencies

- `useAuth()` — reads `claims`, `isStaff`
- `Navigate`, `Outlet` from react-router-dom

#### APIs Used

None.

#### Problems

None significant. The pattern is correct. The role redirect logic is clean.

---

## 3. Pages

---

### Page: Login (`/login`)

**File:** `frontend/src/routes/Login.tsx`
**Accessed by:** Anonymous users (and already-authed users, who are redirected immediately on arrival)
**Recommendation:** REDESIGN

#### Purpose

Single-page authentication form. Collects email and password, calls AWS Cognito via `useAuth().login()`, then redirects to `/` (patient) or `/staff` based on role claims.

#### Current Implementation

```
<div class="flex min-h-screen items-center justify-center bg-surface px-4">
  <Card class="w-full max-w-md">
    <CardHeader>
      <div>"LabLumen"</div>                 ← wordmark as h1 equivalent
      <CardTitle>"Sign in to your account"</CardTitle>
    </CardHeader>
    <CardContent>
      <form onSubmit={onSubmit}>
        <label>Email</label>
        <input type="email" required />     ← raw input, no shared primitive
        <label>Password</label>
        <input type="password" required />  ← no show/hide toggle
        {error && <p class="bg-danger/10">{error}</p>}
        <Button type="submit" disabled={submitting}>
          {submitting ? "Signing in…" : "Sign in"}
        </Button>
      </form>
    </CardContent>
  </Card>
</div>
```

#### State

| Variable | Type | Purpose |
|----------|------|---------|
| `email` | `string` | Controlled email input |
| `password` | `string` | Controlled password input |
| `error` | `string \| null` | Displays Cognito or network error |
| `submitting` | `boolean` | Disables submit button during request |

#### Dependencies

- `useAuth()` — `login()` function
- `useNavigate()` — post-login redirect
- `isStaff()` — determines redirect target from claims
- `Button`, `Card`, `CardContent`, `CardHeader`, `CardTitle`

#### APIs Used

- AWS Cognito (via `lib/cognito.ts` → `amazon-cognito-identity-js`) — SRP authentication
- No backend API called directly from this page

#### Auth Flow

```
Form submit
  → login(email, password)
    → cognitoSignIn()          [lib/cognito.ts]
      → CognitoUser.authenticateUser()
        → onSuccess: extract idToken → setToken() → getClaims()
        → onFailure: throw Error
    → navigate("/staff" | "/")
```

#### Problems

1. No logo or brand illustration — flat generic card
2. No "Forgot password?" link — launch blocker
3. No self-registration link — patients cannot sign up without admin creation
4. No password show/hide toggle
5. Error text is sometimes Cognito's raw error message (verbose), sometimes "Sign-in failed" (generic)
6. `bg-surface` (#F8FAFC) background is indistinct from white
7. The CardTitle "Sign in to your account" is boilerplate copy

#### Redesign Direction

Split-panel layout (hidden on mobile): Left = brand hero with product tagline + trust signals ("AI-powered", "HIPAA-ready", lab imagery). Right = auth form with logo, email/password, show-hide toggle, "Forgot password?" link, submit button. Mobile collapses to centered card with logo above form.

---

### Page: Patient Dashboard (`/`)

**File:** `frontend/src/routes/PatientDashboard.tsx`
**Accessed by:** Authenticated patients only
**Recommendation:** SPLIT into three pages: home dashboard, `/app/book`, `/app/reports`

#### Purpose

The single destination for all patient-facing functionality. Currently hosts the booking form and the complete report list on one page.

#### Current Implementation

```
<div class="grid grid-cols-1 gap-4">

  <BentoCard title="Book a Lab Test">
    <BookingWorkspace />             ← complete booking form, always visible
  </BentoCard>

  <BentoCard title="My Reports">
    {isLoading && <p>"Loading reports…"</p>}
    {reports.length > 0 && (
      <ul class="divide-y">
        {reports.map(r => (
          <li class="flex items-center justify-between py-2">
            <div>
              <p>{r.test_name}</p>
              <p>{r.patient_name} · {date} · <span status></span></p>
            </div>
            <Button onClick={() => setPreviewReport(r)}>View Report</Button>
          </li>
        ))}
      </ul>
    )}
    {reports.length === 0 && <p>"No reports yet…"</p>}
  </BentoCard>

  <ReportPreviewModal
    report={previewReport}
    onClose={() => setPreviewReport(null)}
  />

</div>
```

#### State

| Variable | Type | Purpose |
|----------|------|---------|
| `previewReport` | `Report \| null` | Controls which report is open in the preview modal |

*All booking-related state lives inside `BookingWorkspace` (see component section).*

#### Dependencies

- `BookingWorkspace` — full booking form
- `BentoCard` — card wrapper
- `ReportPreviewModal` — full-screen report + AI modal
- `Button` — "View Report" trigger
- `useReports()` hook — fetches patient's reports with polling

#### APIs Used (via hooks)

| API Call | Hook | Endpoint |
|----------|------|----------|
| List reports | `useReports()` | `GET /api/v1/reports` |

#### Polling Behavior

`useReports` polls every 4 seconds when any report has `!has_summary && !processing_failed`. Stops polling once all reports reach a terminal state. This means the page actively refetches during AI processing.

#### Report List — Status Display Logic

| Condition | Display |
|-----------|---------|
| `r.has_summary === true` | `<span class="text-success">Ready</span>` |
| `r.processing_failed === true` | `<span class="text-danger">Processing failed</span>` |
| Neither | `<span class="text-warning">Processing…</span>` |

#### Problems

1. Booking and reports are cognitively unrelated tasks on the same page
2. No appointment history — only reports, not upcoming bookings
3. No filtering, sorting, or search on the report list
4. Status is inline text; no badge component
5. Report rows show patient name (redundant — patient is viewing their own) and no test date context
6. Empty state is a single line of muted text
7. Loading state is a single line of muted text
8. No "New" badge for recently added reports
9. No way to navigate between reports without closing and reopening the modal
10. `previewReport` state is reset to `null` on close — chat history is lost

#### Redesign Direction

**Replace with three routes:**

`/app` — Patient home: welcome header, "Next appointment" widget, "Latest report" widget with status, quick-action buttons ("Book a test →", "View reports →")

`/app/book` — Multi-step booking wizard (see BookingWorkspace redesign)

`/app/reports` — Paginated, filterable report list: sort by date, filter by status (Ready / Processing / Failed), search by test name. Each row is a card link to `/app/reports/:id`

---

### Page: Staff Dashboard (`/staff`)

**File:** `frontend/src/routes/StaffDashboard.tsx`
**Accessed by:** Authenticated staff and admin users
**Recommendation:** REDESIGN — significant additions required, core structure can remain

#### Purpose

Operations hub for lab staff. Displays summary metrics, and a table of all patient orders where staff can upload PDF reports.

#### Current Implementation

```
<div class="grid grid-cols-1 gap-4 md:grid-cols-3">

  <BentoCard title="Today's Scheduled Volume">
    <p class="text-3xl text-primary">{stats.today}</p>
  </BentoCard>

  <BentoCard title="Pending PDF Uploads">
    <p class="text-3xl text-warning">{stats.pendingUploads}</p>
  </BentoCard>

  <BentoCard title="Total Orders">
    <p class="text-3xl text-text-dark">{stats.total}</p>
  </BentoCard>

  <BentoCard title="Operations Queue" class="md:col-span-3">
    {isLoading && <p>"Loading queue…"</p>}
    {ops.length > 0 && (
      <table>
        <thead>Patient | Test | When | Report</thead>
        <tbody>
          {ops.map(row => <OpsRowItem key={row.mapping_id} row={row} />)}
        </tbody>
      </table>
    )}
    {ops.length === 0 && <p>"No orders yet…"</p>}
  </BentoCard>

</div>
```

#### Stat Computation (derived from `ops` data)

```typescript
const stats = useMemo(() => {
  const today = new Date().toISOString().slice(0, 10);
  const appts = new Set(ops?.map(r => r.appointment_id));
  const todayAppts = new Set(
    ops?.filter(r => r.appointment_date === today).map(r => r.appointment_id)
  );
  const pendingUploads = ops?.filter(r => !r.has_report).length ?? 0;
  return { total: appts.size, today: todayAppts.size, pendingUploads };
}, [ops]);
```

*All three stats are derived client-side from the `ops` array — no separate stats API.*

#### State

All state is contained within the inline `OpsRowItem` sub-component (see Component Groups section).

#### Dependencies

- `OpsRowItem` (inline sub-component — not extracted to its own file)
- `BentoCard` — card wrapper
- `Button`, `Upload` (lucide-react)
- `useOps()` hook — fetches operations queue
- `useMutation` — for PDF upload

#### APIs Used

| API Call | Hook/Component | Endpoint |
|----------|---------------|----------|
| List ops queue | `useOps()` | `GET /api/v1/appointments/ops` |
| Upload PDF | `OpsRowItem` → `useMutation` | `POST /api/v1/reports/upload` |

#### Ops Queue — Row States

| Condition | UI Shown |
|-----------|---------|
| `row.has_report === true` | `<span class="text-success">Report uploaded</span>` |
| `row.has_report === false` | Upload button + hidden file input |
| `upload.isPending` | "Uploading…" (button disabled) |
| Upload success | "Uploaded — AI processing started." |
| Upload error | Error message string |

#### Problems

1. No date filter — table shows all historical orders
2. No patient name search
3. No status filter (pending / uploaded / AI processing / AI complete / AI failed)
4. No sortable columns
5. Stats are all-time counts or same-day counts — no context (vs. yesterday, completion rate)
6. `OpsRowItem` is defined inline in the same file — not extracted
7. `updateAppointmentStatus` API exists but is never called — no status management UI
8. No AI processing status visible after upload
9. No drag-and-drop upload — only click-triggered hidden file input
10. No pagination
11. Upload feedback (success/error) is a small inline `<p>` that does not persist

#### Redesign Direction

Add date picker at top defaulting to today. Add search input. Add status filter tabs. Add sortable column headers. Extract `OpsRowItem` to its own file. Add drag-and-drop upload zone. Replace stat cards with: Scheduled Today, Completed, Pending Upload, AI Processing, AI Failed. Add appointment status dropdown to each row (Scheduled / In Progress / Completed / No Show / Cancelled). Show AI processing status in the report column after upload.

---

## 4. Component Groups

---

### Component: `BookingWorkspace`

**File:** `frontend/src/components/BookingWorkspace.tsx`
**Used by:** PatientDashboard
**Recommendation:** REWRITE as multi-step `/app/book` page

#### Purpose

The complete lab test booking form. Handles patient profile selection/creation, test selection, date/time picking, price calculation, and appointment submission.

#### Current Implementation Structure

```
<div class="space-y-4">

  ── Section 1: Patient Selection ─────────────────────────────────
  {patients.length > 0 && (
    <select>            ← dropdown of existing patient profiles
    <Button>"Add profile" | "Cancel"</Button>
  )}
  {patients.length === 0 && (
    <p>"No patient profiles yet…" <Button>Add profile</Button></p>
  )}

  ── Inline Profile Form (conditional) ────────────────────────────
  {showProfileForm && (
    <div class="grid grid-cols-2 gap-3 bg-surface p-3">
      <input placeholder="First name" />
      <input placeholder="Last name" />
      <input placeholder="Phone" />
      <input type="date" />           ← date of birth
      <select>Male|Female|Other</select>
      <input placeholder="Relationship (e.g. Self)" />   ← should be select
      <Button class="col-span-2">Save profile</Button>
    </div>
  )}

  ── Section 2: Test Selection ─────────────────────────────────────
  <label>"Select tests"</label>
  <div class="grid grid-cols-1 sm:grid-cols-2">
    {tests.map(t => (
      <label class="flex cursor-pointer items-center justify-between border">
        <input type="checkbox" /> {t.name}
        <span>${t.base_cost}</span>
      </label>
    ))}
  </div>

  ── Section 3: Date + Time ────────────────────────────────────────
  <div class="grid grid-cols-2 gap-3">
    <input type="date" />             ← native date picker
    <select>                          ← hardcoded TIME_SLOTS array
      {TIME_SLOTS.map(s => <option>{s}</option>)}
    </select>
  </div>

  ── Section 4: Total + Submit ─────────────────────────────────────
  <div class="flex items-center justify-between border-t">
    <span>{selectedTests.size} test(s) · ${total}</span>
    <Button disabled={!canBook}>Book appointment</Button>
  </div>

  {feedback && <p class="bg-success/10 | bg-danger/10">{feedback.text}</p>}

</div>
```

#### State (7 variables)

| Variable | Type | Purpose |
|----------|------|---------|
| `patientId` | `string` | Selected patient profile ID |
| `selectedTests` | `Set<string>` | Set of selected test IDs |
| `date` | `string` | ISO date string for appointment |
| `slot` | `string` | Selected time slot (default: `"09:00"`) |
| `showProfileForm` | `boolean` | Toggles inline profile creation form |
| `profile` | `PatientProfileCreate` | Controlled state for new profile form |
| `feedback` | `{ kind: "ok"\|"err"; text: string } \| null` | Success/error message |

#### Hardcoded Values

```typescript
const TIME_SLOTS = [
  "09:00", "09:30", "10:00", "10:30", "11:00", "11:30",
  "14:00", "14:30", "15:00", "15:30", "16:00"
];
```

This list is not fetched from the API. Real slot availability is not reflected.

#### Mutations

| Mutation | API Call | On Success | On Error |
|----------|----------|------------|---------|
| `createProfile` | `POST /api/v1/patients` | Invalidates `["patients"]`, sets `patientId`, hides profile form | Shows error feedback |
| `book` | `POST /api/v1/appointments` | Invalidates `["appointments"]`, clears tests/date, shows success feedback | Shows error feedback |

#### APIs Used

| API Call | Hook | Endpoint |
|----------|------|----------|
| List lab tests | `useLabTests()` | `GET /api/v1/lab-tests` |
| List patient profiles | `usePatients()` | `GET /api/v1/patients` |
| Create patient profile | `useMutation` | `POST /api/v1/patients` |
| Book appointment | `useMutation` | `POST /api/v1/appointments` |

#### Booking Payload Shape

```typescript
{
  appointment_date: string,          // "YYYY-MM-DD"
  time_slot: string,                 // "09:00"
  tests: Array<{
    test_id: string,
    patient_id: string
  }>
}
```

#### Booking Enable Condition

```typescript
const canBook = activePatient && selectedTests.size > 0 && date && slot && !book.isPending;
```

#### Problems

1. Flat form with no step progression — 4 logical steps appear as one long form
2. No confirmation screen before submitting
3. Profile creation is inline — disrupts the booking flow
4. Time slots are hardcoded — real availability unknown
5. No test descriptions — only name and price visible
6. No test categories or grouping
7. 7 useState calls in one component — needs decomposition
8. Relationship field is a free-text input (placeholder "e.g. Self") — should be a select with options: Self, Child, Spouse, Parent, Other
9. Success feedback disappears on component re-render
10. No way to clear the selection and start over
11. Profile form labels are placeholders only — no visible `<label>` elements in the grid form (accessibility failure)

---

### Component: `OpsRowItem` (inline in StaffDashboard)

**File:** `frontend/src/routes/StaffDashboard.tsx` (defined inline)
**Used by:** StaffDashboard (as `<OpsRowItem />`)
**Recommendation:** EXTRACT to `frontend/src/components/OpsRowItem.tsx`, then REDESIGN with drag-and-drop

#### Purpose

Renders a single row in the staff operations queue table. Handles PDF upload for a specific appointment-test mapping.

#### Current Implementation

```
<tr class="border-b last:border-0">
  <td>{row.patient_name}</td>
  <td>{row.test_name}</td>
  <td>{row.appointment_date} {row.time_slot}</td>
  <td class="text-right">
    {row.has_report
      ? <span class="text-success">Report uploaded</span>
      : <>
          <input type="file" ref={fileRef} class="hidden" onChange={...} />
          <Button onClick={() => fileRef.current?.click()}>
            <Upload /> Upload PDF
          </Button>
        </>
    }
    {note && <p class="text-[11px] text-text-muted">{note}</p>}
  </td>
</tr>
```

#### State

| Variable | Type | Purpose |
|----------|------|---------|
| `note` | `string \| null` | Per-row upload success/error message |

#### Mutation

| Mutation | API Call | On Success | On Error |
|----------|----------|------------|---------|
| `upload` | `POST /api/v1/reports/upload` | Sets note "Uploaded — AI processing started.", invalidates `["ops"]` | Sets note with error message |

#### Upload Payload

```
FormData:
  mapping_id: string    ← row.mapping_id
  file: File            ← selected .pdf / .png / .jpg / .jpeg
```

#### APIs Used

| API Call | Endpoint |
|----------|----------|
| Upload report PDF | `POST /api/v1/reports/upload` |

#### Problems

1. Defined inline — not extractable without refactoring the parent file
2. Hidden file input pattern — no drag-and-drop
3. Accepted formats: `.pdf,.png,.jpg,.jpeg` — accepting images for "Upload PDF" is inconsistent with the label
4. `note` state is local — resets if the component re-renders (e.g., after `invalidateQueries`)
5. No upload progress indicator
6. No AI processing status shown after successful upload
7. No way to re-upload if a wrong file is submitted (once `has_report` is true, the upload button disappears)
8. `text-[11px]` for feedback text — not a design system value

---

### Component: `BentoCard`

**File:** `frontend/src/components/BentoCard.tsx`
**Used by:** PatientDashboard (×2), StaffDashboard (×4)
**Recommendation:** KEEP — add `action` slot prop

#### Purpose

A styled card wrapper with a title header and content body. The primary layout unit for both dashboards.

#### Current Implementation

```typescript
interface BentoCardProps {
  title: string;
  className?: string;
  children: ReactNode;
}

// Renders: Card > CardHeader > CardTitle + CardContent > children
```

#### Dependencies

- `Card`, `CardHeader`, `CardTitle`, `CardContent` (ui/card)
- `cn` (lib/utils)

#### Problems

1. No `action` slot — cannot add a button or link to the card header (e.g., "View all →" on the reports card, or a date picker on the staff queue card)
2. `title` is always a string — cannot pass a React node for rich header content
3. No variant prop — all cards look identical regardless of semantic importance

#### Proposed API Extension

```typescript
interface BentoCardProps {
  title: string | ReactNode;
  action?: ReactNode;       // ← rendered right-aligned in header
  variant?: "default" | "stat" | "highlight";
  className?: string;
  children: ReactNode;
}
```

---

## 5. UI Primitives

---

### Primitive: `Button`

**File:** `frontend/src/components/ui/button.tsx`
**Used by:** Login, PatientDashboard, StaffDashboard, BookingWorkspace, ReportPreviewModal, ReportChatModal, Layout
**Recommendation:** KEEP — add `loading` and `destructive` variants

#### Current Variants

| Variant | Styles | Use Case |
|---------|--------|---------|
| `default` | `bg-primary text-white hover:bg-primary/90` | Primary CTA |
| `outline` | `border border-slate-200 bg-white hover:bg-surface` | Secondary action |
| `ghost` | `hover:bg-surface` | Tertiary / icon buttons |

#### Current Sizes

| Size | Dimensions | Use Case |
|------|-----------|---------|
| `default` | `h-10 px-4 py-2` | Standard buttons |
| `sm` | `h-9 px-3` | Compact table/list actions |
| `icon` | `h-10 w-10` | Square icon-only buttons |

#### Focus / Disabled States

- Focus: `focus-visible:ring-2 focus-visible:ring-primary`
- Disabled: `disabled:pointer-events-none disabled:opacity-50`

#### Missing Variants

| Variant | Purpose |
|---------|---------|
| `destructive` | Delete / cancel / danger actions (e.g., cancel appointment) |
| `loading` | Spinner + disabled state for async actions (currently done via `disabled` + text change only) |

---

### Primitive: `Card`, `CardHeader`, `CardTitle`, `CardContent`

**File:** `frontend/src/components/ui/card.tsx`
**Used by:** Login (directly), BentoCard (wraps it)
**Recommendation:** KEEP — add `CardFooter`, size variants

#### Current Implementation

```
Card:       rounded-bento border border-slate-100 bg-white shadow-bento-diffused
CardHeader: p-5 pb-2
CardTitle:  text-base font-semibold text-text-dark
CardContent: p-5 pt-2
```

#### Missing Sub-components

- `CardFooter` — for action buttons at the bottom of a card (e.g., booking form submit row)
- `CardDescription` — for subtitle text below the card title

---

### Missing Primitives (Needed for Launch)

| Component | File Location (proposed) | Priority | Purpose |
|-----------|--------------------------|----------|---------|
| `Input` | `ui/input.tsx` | Critical | Shared styled input with label, error state, focus ring |
| `Select` | `ui/select.tsx` | Critical | Shared styled select / dropdown |
| `Badge` | `ui/badge.tsx` | High | Status chips (Ready, Processing, Failed, Pending) |
| `Skeleton` | `ui/skeleton.tsx` | High | Animated placeholder for loading states |
| `Toast` / `Toaster` | `ui/toast.tsx` | High | Transient success/error notifications |
| `Dialog` | `ui/dialog.tsx` | High | Accessible modal primitive with focus trap + Escape |
| `Tabs` | `ui/tabs.tsx` | High | Staff queue status filter, mobile report tabs |
| `Spinner` | `ui/spinner.tsx` | Medium | Inline loading indicator |
| `EmptyState` | `ui/empty-state.tsx` | Medium | Illustrated empty view with CTA |
| `Calendar` | `ui/calendar.tsx` | High | Date picker for booking |
| `FormField` | `ui/form-field.tsx` | Medium | Label + Input + error message wrapper |
| `Avatar` | `ui/avatar.tsx` | Low | User profile image / initials in header |

---

## 6. Modals

---

### Modal: `ReportPreviewModal`

**File:** `frontend/src/components/ReportPreviewModal.tsx`
**Triggered by:** PatientDashboard — clicking "View Report" sets `previewReport` state
**Recommendation:** REWRITE — convert to `/app/reports/:id` page, extract sub-components

#### Purpose

The core patient report experience. A full-screen overlay with:
- Left panel (70%): PDF viewer via `<iframe>`
- Right panel (30%): Tabbed between AI Summary and Chat

#### Layout Structure

```
<div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
  <div class="flex h-[90vh] w-full max-w-6xl overflow-hidden rounded-bento bg-white">

    ── Left: PDF Viewer (70%) ──────────────────────────────────────
    <div class="flex w-[70%] flex-col border-r">
      <header>
        "Diagnostic Report Preview" | {report.test_name}
        [Download PDF link] [×Close button]
      </header>
      <div class="flex-1 overflow-hidden bg-slate-50">
        {pdfLoading && "Loading PDF…"}
        {pdfUrl && <iframe src={pdfUrl} />}
        {!pdfUrl && !pdfLoading && "Could not load PDF"}
      </div>
    </div>

    ── Right: Summary / Chat (30%) ──────────────────────────────────
    <div class="relative flex w-[30%] flex-col overflow-hidden">

      ── Summary Panel (panel === "summary") ──────────────────────
      <header>"AI Summary" | {report.patient_name}</header>
      <div class="flex-1 overflow-y-auto p-4 pb-20">
        {report.summary && <Markdown>{report.summary}</Markdown>}
        {report.processing_failed && <p class="text-danger">…</p>}
        {!report.summary && !report.processing_failed && <p>Still processing…</p>}
      </div>
      {report.has_summary && (
        <button class="absolute bottom-5 right-5 rounded-full bg-primary h-12 w-12">
          <MessageCircle />                    ← FAB to open chat
        </button>
      )}

      ── Chat Panel (panel === "chat") ────────────────────────────
      <header>
        <button><ArrowLeft /></button>         ← back to summary
        "Ask your report" | {report.test_name}
      </header>
      <div ref={scrollRef} class="flex-1 overflow-y-auto bg-surface p-4">
        {messages.length === 0 && <p>Ask anything…</p>}
        {messages.map(m => (
          <div class={m.role === "user" ? "flex justify-end" : "flex justify-start"}>
            <div class={m.role === "user" ? "bg-primary text-white" : "bg-white shadow"}>
              {m.role === "assistant" ? <Markdown>{m.content}</Markdown> : m.content}
            </div>
          </div>
        ))}
        {sending && <p class="italic text-text-muted">Thinking…</p>}
        {chatError && <p class="text-danger">{chatError}</p>}
      </div>
      <p class="bg-warning/5 text-xs">For general understanding only…</p>  ← disclaimer
      <form onSubmit={sendMessage}>
        <input ref={inputRef} value={input} placeholder="Type your question…" />
        <Button type="submit" size="icon"><Send /></Button>
      </form>

    </div>
  </div>
</div>
```

#### State

| Variable | Type | Purpose |
|----------|------|---------|
| `pdfUrl` | `string \| null` | Presigned S3 URL for the PDF iframe |
| `pdfLoading` | `boolean` | PDF URL fetch in progress |
| `panel` | `"summary" \| "chat"` | Which right-panel is active |
| `messages` | `ChatMessage[]` | Full chat history for this session |
| `input` | `string` | Controlled chat input value |
| `sending` | `boolean` | Chat request in flight |
| `chatError` | `string \| null` | Last chat error message |

#### Refs

| Ref | Attached To | Purpose |
|-----|------------|---------|
| `scrollRef` | Chat messages container | Auto-scroll to bottom after new message |
| `inputRef` | Chat text input | Focus on chat panel open |

#### Effect

```typescript
useEffect(() => {
  if (!report) return;
  // Reset all state on report change
  setPdfUrl(null);
  setPdfLoading(true);
  setPanel("summary");
  setMessages([]);
  setInput("");
  setChatError(null);
  // Fetch presigned PDF URL
  api.viewReport(report.report_id)
    .then(({ url }) => setPdfUrl(url))
    .catch(() => {})
    .finally(() => setPdfLoading(false));
}, [report?.report_id]);
```

#### APIs Used

| API Call | Trigger | Endpoint |
|----------|---------|----------|
| Get presigned PDF URL | On `report` prop change | `GET /api/v1/reports/:id/view` |
| Chat with report | Form submit | `POST /api/v1/reports/:id/chat` |

#### Chat Request Payload

```typescript
{
  question: string,
  history: Array<{ role: "user" | "assistant", content: string }>
}
```

#### Chat Response Shape

```typescript
{
  answer: string,      // markdown string
  disclaimer: string   // medical disclaimer text (not used in this component)
}
```

#### Problems

1. `w-[70%]` / `w-[30%]` fixed widths — no responsive breakpoints. **Broken on mobile.**
2. No focus trap — Tab key escapes the modal
3. No Escape key handler
4. No `aria-labelledby` connecting modal to its title
5. Chat FAB (`absolute bottom-5 right-5`) overlaps summary content
6. No "clear chat" or "new conversation" button
7. Chat history is lost when modal closes (state resets on `report` prop change)
8. Disclaimer appears in chat panel only — not when viewing AI summary
9. No copy-to-clipboard on AI summary or individual responses
10. No deep-link URL — cannot share a specific report
11. 30% panel (~345px at max-width) is too narrow for comfortable AI response reading
12. `disclaimer` field from chat API response is unused (the component uses a hardcoded string instead)
13. The `role="dialog"` is correct but `aria-modal="true"` without a focus trap is misleading

---

### Modal: `ReportChatModal` ← DEAD CODE

**File:** `frontend/src/components/ReportChatModal.tsx`
**Triggered by:** **Nothing** — this component is never imported or rendered anywhere in the application
**Recommendation:** DELETE immediately

#### Purpose (intended)

A standalone chat-only modal for querying a specific report. This was likely an earlier implementation before the chat was integrated into `ReportPreviewModal`.

#### Why It Exists

This appears to have been replaced when the 70/30 report preview layout was designed. The chat functionality was absorbed into `ReportPreviewModal` as a panel. `ReportChatModal` was never removed.

#### Differences from `ReportPreviewModal` Chat Panel

| Feature | ReportPreviewModal chat | ReportChatModal |
|---------|------------------------|----------------|
| Has PDF viewer | Yes | No |
| Has AI summary | Yes | No |
| Chat width | 30% of 6xl modal | 100% of max-w-2xl modal (better) |
| Disclaimer handling | Hardcoded string | Uses API-returned `res.disclaimer` |
| Message history | `ChatMessage[]` with role | Same shape |
| Error display | Same | Same |

#### Impact of Dead Code

- Adds ~150 lines of unused TypeScript to the bundle
- Creates confusion — a future developer reading the codebase will wonder which chat component is in use
- The `disclaimer` handling in `ReportChatModal` is actually more correct (uses the API-returned value) — this is a regression in `ReportPreviewModal`

---

## 7. Hooks

---

### Hook: `useLabTests`

**File:** `frontend/src/hooks/useLabTests.ts`
**Used by:** BookingWorkspace

#### Implementation

```typescript
export function useLabTests() {
  return useQuery<LabTest[]>({
    queryKey: ["lab-tests"],
    queryFn: api.listLabTests,
  });
}
```

#### Behavior

- Uses global `queryClient` defaults: `staleTime: 30_000`, `retry: 1`, `refetchOnWindowFocus: false`
- No custom `refetchInterval` — fetches once, stale after 30s
- Appropriate for lab test catalog (rarely changes)

#### Returns

```typescript
LabTest[] = Array<{
  test_id: string;
  name: string;
  description: string;       // present in type but not displayed in UI
  base_cost: number | string;
  is_active: boolean;
}>
```

*Note: `description` is in the type definition but never displayed in `BookingWorkspace`. A redesigned booking flow should show descriptions.*

---

### Hook: `usePatients`

**File:** `frontend/src/hooks/usePatients.ts`
**Used by:** BookingWorkspace

#### Implementation

```typescript
export function usePatients() {
  return useQuery<PatientProfile[]>({
    queryKey: ["patients"],
    queryFn: api.listPatients,
  });
}
```

#### Behavior

Standard query with global defaults. Returns all patient profiles associated with the logged-in user account.

#### Returns

```typescript
PatientProfile[] = Array<{
  patient_id: string;
  first_name: string;
  last_name: string;
  phone_number: string;
  date_of_birth: string;
  biological_gender: string;
  relationship_to_owner: string;
}>
```

---

### Hook: `useReports`

**File:** `frontend/src/hooks/useReports.ts`
**Used by:** PatientDashboard

#### Implementation

```typescript
export function useReports() {
  return useQuery<Report[]>({
    queryKey: ["reports"],
    queryFn: api.listReports,
    refetchInterval: (query) =>
      query.state.data?.some(r => !r.has_summary && !r.processing_failed)
        ? 4000
        : false,
  });
}
```

#### Polling Logic

- Polls every 4 seconds **only while** any report is in a non-terminal state (`!has_summary && !processing_failed`)
- Stops polling once all reports are either `has_summary === true` or `processing_failed === true`
- This is the most sophisticated hook in the codebase — correct implementation of conditional polling

#### Returns

```typescript
Report[] = Array<{
  report_id: string;
  test_name: string;
  patient_name: string;
  created_at: string;          // ISO datetime
  has_summary: boolean;
  summary: string | null;      // markdown string when ready
  processing_failed: boolean;
}>
```

---

### Hook: `useOps`

**File:** `frontend/src/hooks/useOps.ts`
**Used by:** StaffDashboard

#### Implementation

```typescript
export function useOps() {
  return useQuery<OpsRow[]>({
    queryKey: ["ops"],
    queryFn: api.listOps,
  });
}
```

#### Behavior

Standard query with global defaults. No polling. Returns all appointment-test mappings across all dates.

#### Returns

```typescript
OpsRow[] = Array<{
  mapping_id: string;
  appointment_id: string;
  appointment_date: string;    // "YYYY-MM-DD"
  time_slot: string;           // "09:00"
  status: string;              // appointment status (unused in UI)
  patient_name: string;
  test_name: string;
  price_at_booking: string;
  report_id: string | null;
  has_report: boolean;
}>
```

*Note: `status` and `price_at_booking` are returned by the API but never displayed in the current UI.*

---

## 8. API Layer

---

### API Configuration

**File:** `frontend/src/lib/api.ts`

Two base URLs, configurable via environment variables:

```typescript
const APPOINTMENT_API = import.meta.env.VITE_APPOINTMENT_API ?? "http://localhost:8001";
const REPORT_API = import.meta.env.VITE_REPORT_API ?? "http://localhost:8002";
```

All requests go through a shared `request<T>()` helper that:
1. Reads the JWT from localStorage via `getToken()`
2. Attaches `Authorization: Bearer <token>` header
3. Handles `FormData` (skips `Content-Type: application/json` for multipart)
4. On `401`: clears token, redirects to `/login`
5. On non-OK: parses error `detail` field from response body
6. On `204`: returns `undefined`
7. Otherwise: returns `response.json()` cast to `T`

---

### Complete API Method Reference

#### Appointment Service (`VITE_APPOINTMENT_API` — default `:8001`)

| Method | HTTP | Endpoint | Payload | Returns | Used In |
|--------|------|----------|---------|---------|---------|
| `listLabTests()` | GET | `/api/v1/lab-tests` | — | `LabTest[]` | `useLabTests` |
| `listPatients()` | GET | `/api/v1/patients` | — | `PatientProfile[]` | `usePatients` |
| `createPatient(payload)` | POST | `/api/v1/patients` | `PatientProfileCreate` | `PatientProfile` | `BookingWorkspace` |
| `bookAppointment(payload)` | POST | `/api/v1/appointments` | `BookingPayload` | `Appointment` | `BookingWorkspace` |
| `listMyAppointments()` | GET | `/api/v1/appointments` | — | `Appointment[]` | **Unused — no UI** |
| `listOps()` | GET | `/api/v1/appointments/ops` | — | `OpsRow[]` | `useOps` |
| `updateAppointmentStatus(id, status)` | PATCH | `/api/v1/appointments/:id/status?new_status=X` | — | `Appointment` | **Unused — no UI** |

#### Report Service (`VITE_REPORT_API` — default `:8002`)

| Method | HTTP | Endpoint | Payload | Returns | Used In |
|--------|------|----------|---------|---------|---------|
| `listReports()` | GET | `/api/v1/reports` | — | `Report[]` | `useReports` |
| `viewReport(reportId)` | GET | `/api/v1/reports/:id/view` | — | `ReportView` | `ReportPreviewModal` |
| `uploadReport(mappingId, file)` | POST | `/api/v1/reports/upload` | `FormData` | `{ report_id, status }` | `OpsRowItem` |
| `chatWithReport(reportId, question, history)` | POST | `/api/v1/reports/:id/chat` | `ChatPayload` | `ChatResponse` | `ReportPreviewModal`, `ReportChatModal` (dead) |

#### Unused API Methods (defined but never called from any rendered component)

| Method | Notes |
|--------|-------|
| `listMyAppointments()` | Patient appointment history — no page exists for this |
| `updateAppointmentStatus()` | Appointment lifecycle management — no UI exists |

---

### API Type Reference

```typescript
// ─── Request Types ────────────────────────────────────────────
interface PatientProfileCreate {
  first_name: string;
  last_name: string;
  phone_number: string;
  date_of_birth: string;        // "YYYY-MM-DD"
  biological_gender: string;    // "Male" | "Female" | "Other"
  relationship_to_owner: string;
}

interface BookingPayload {
  appointment_date: string;     // "YYYY-MM-DD"
  time_slot: string;            // "09:00"
  tests: Array<{
    test_id: string;
    patient_id: string;
  }>;
}

interface ChatHistoryItem {
  role: "user" | "assistant";
  content: string;
}

// ─── Response Types ───────────────────────────────────────────
interface LabTest {
  test_id: string;
  name: string;
  description: string;
  base_cost: number | string;   // inconsistent — can be either
  is_active: boolean;
}

interface PatientProfile {
  patient_id: string;
  first_name: string;
  last_name: string;
  phone_number: string;
  date_of_birth: string;
  biological_gender: string;
  relationship_to_owner: string;
}

interface Appointment {
  appointment_id: string;
  appointment_date: string;
  time_slot: string;
  status: string;
}

interface OpsRow {
  mapping_id: string;
  appointment_id: string;
  appointment_date: string;
  time_slot: string;
  status: string;
  patient_name: string;
  test_name: string;
  price_at_booking: string;
  report_id: string | null;
  has_report: boolean;
}

interface Report {
  report_id: string;
  test_name: string;
  patient_name: string;
  created_at: string;
  has_summary: boolean;
  summary: string | null;
  processing_failed: boolean;
}

interface ReportView {
  url: string;
  expires_in: number;
}

interface ChatResponse {
  answer: string;
  disclaimer: string;
}
```

---

## 9. Auth System

---

### Auth Flow Overview

```
User submits login form
    │
    ▼
lib/AuthContext.tsx → login(email, password)
    │
    ▼
lib/cognito.ts → signIn(email, password)
    │   Uses: amazon-cognito-identity-js
    │   Calls: CognitoUser.authenticateUser() — SRP flow
    │
    ├── onSuccess:
    │   └── Returns { idToken, email, groups }
    │
    └── onFailure:
        └── Throws Error (Cognito error message)

Back in AuthContext:
    │
    ▼
lib/auth.ts → setToken(idToken)         ← stores in localStorage["lablumen.token"]
lib/auth.ts → getClaims()              ← decodes JWT, checks expiry
    │
    ▼
setClaims(next)                         ← updates React Context
    │
    ▼
navigate("/staff" | "/")               ← role-based redirect
```

### Token Storage

| Key | Value | Location |
|-----|-------|---------|
| `lablumen.token` | AWS Cognito ID token (JWT) | `localStorage` |

**Security note:** localStorage is vulnerable to XSS attacks. `httpOnly` cookies would be more secure but require backend changes. This is a known, documented trade-off.

### Token Decode (Client-Side)

```typescript
// lib/auth.ts — getClaims()
// Decodes the JWT payload WITHOUT signature verification
// Checks: token exists, decode succeeds, exp > Date.now()
// Extracts: sub, email, cognito:groups, exp
```

### Role Detection

```typescript
const STAFF_GROUPS = ["LAB_STAFF", "LAB_ADMIN"];

function isStaff(claims: Claims | null = getClaims()): boolean {
  return Boolean(claims?.groups.some(g => STAFF_GROUPS.includes(g)));
}
```

Patients are the default role — any authenticated user who is not in `LAB_STAFF` or `LAB_ADMIN` is treated as a patient.

### Session Expiry Handling

Two paths:

1. **On navigation** — `ProtectedRoute` calls `getClaims()` which checks `exp`. Expired → redirect to `/login`.
2. **On API call** — The `request()` helper intercepts `401` responses: clears token, redirects to `window.location.href = "/login"` (hard refresh, loses React state).

### Logout Flow

```typescript
// AuthContext.tsx → logout()
if (claims?.email) signOutCognito(claims.email);  // Cognito global sign-out
clearToken();                                       // Remove from localStorage
setClaims(null);                                    // Clear React Context
// Then navigate("/login") from Layout.tsx
```

### Auth Context Shape

```typescript
interface AuthContextValue {
  claims: Claims | null;     // null when not logged in
  isStaff: boolean;          // derived from claims.groups
  login: (email, password) => Promise<Claims>;
  logout: () => void;
}

interface Claims {
  sub: string;               // Cognito user UUID
  email?: string;
  groups: string[];          // ["LAB_STAFF"] | ["LAB_ADMIN"] | []
  exp: number;               // Unix timestamp
}
```

---

## 10. User Flows

---

### Flow 1: First-Time Patient Login and Profile Creation

```
[Anonymous] visits any URL
    │
    ▼
ProtectedRoute: no claims → redirect to /login
    │
    ▼
[Login page] enters email + password → submits
    │
    ▼
Cognito SRP auth → ID token → localStorage
    │
    ▼
isStaff(claims) === false → navigate("/")
    │
    ▼
[Patient Dashboard] loads
    ├── useReports() fires → GET /api/v1/reports → [] (empty)
    └── BookingWorkspace mounts:
        ├── useLabTests() fires → GET /api/v1/lab-tests → [tests]
        └── usePatients() fires → GET /api/v1/patients → [] (empty)

Patient sees: "No patient profiles yet — add one to start booking."
    │
    ▼
Clicks "Add profile" → showProfileForm = true
    │
    ▼
Fills 6-field inline form (first/last name, phone, DOB, gender, relationship)
    │
    ▼
Clicks "Save profile" → createProfile.mutate()
    → POST /api/v1/patients
    → invalidates ["patients"]
    → setPatientId(created.patient_id)
    → showProfileForm = false

Patient can now proceed to book.
```

**Problems:** Profile creation is inline in the booking form. First-time users have no guidance. The inline expand is jarring and the form has no visible `<label>` elements.

---

### Flow 2: Patient Books a Lab Test

```
[Patient Dashboard] — patient profile exists
    │
    ▼
BookingWorkspace shows:
    ├── Patient select dropdown (profiles from usePatients)
    ├── Test checkboxes (from useLabTests)
    ├── Date input (native)
    └── Time slot select (hardcoded 11 options)

Patient:
  1. Selects patient profile (or uses default: first in list)
  2. Checks test checkboxes → total updates in real time
  3. Picks date → native date picker
  4. Picks time slot → select dropdown
  5. Clicks "Book appointment" (enabled when: patient + ≥1 test + date + slot)

book.mutate() fires:
    → POST /api/v1/appointments {
        appointment_date, time_slot,
        tests: [{ test_id, patient_id }, ...]
      }
    → invalidates ["appointments"]
    → clears selectedTests, date
    → feedback = { kind: "ok", text: "Appointment booked. A confirmation email is on its way." }

Feedback appears as green text below the submit button.
```

**Problems:** No confirmation step. Feedback disappears on re-render. Time slots are hardcoded. No calendar UI. No appointment visible after booking.

---

### Flow 3: Patient Views Report and Reads AI Summary

```
[Patient Dashboard] → My Reports card
    │
    useReports() → GET /api/v1/reports → Report[]
    Polls every 4s if any report is processing
    │
    ▼
Report list renders:
    {r.test_name}
    {r.patient_name} · {date} · {status}
    [View Report] button
    │
    ▼
Patient clicks [View Report]
    → setPreviewReport(report)
    → ReportPreviewModal renders with report prop
    │
    ▼
Modal mounts:
    → useEffect fires on report.report_id
    → api.viewReport(reportId) → GET /api/v1/reports/:id/view
    → returns { url: "presigned-s3-url", expires_in: 3600 }
    → setPdfUrl(url)
    │
    ▼
Modal shows:
    Left (70%): <iframe src={pdfUrl} />
    Right (30%): AI Summary panel
        ├── If has_summary: <Markdown>{report.summary}</Markdown>
        ├── If processing_failed: "AI summary could not be generated"
        └── Otherwise: "Summary is still processing…"

    If has_summary: floating [💬] FAB appears (bottom-right of right panel)
```

**Problems:** Modal broken on mobile. No Escape to close. FAB overlaps content. No copy-to-clipboard.

---

### Flow 4: Patient Chats With AI About Report

```
[ReportPreviewModal] — Summary panel — has_summary === true
    │
    ▼
Patient clicks floating [💬] FAB
    → setPanel("chat")
    → inputRef.current?.focus()
    │
    ▼
Chat panel renders:
    ← Back arrow | "Ask your report" | {report.test_name}
    [empty messages area with prompt text]
    [disclaimer: "For general understanding only — not medical advice."]
    [input] [Send ▶]

Patient types question → submits form
    → sendMessage() fires:
        → const history = messages.map(m => ({ role, content }))
        → setMessages([...messages, { role: "user", content: question }])
        → setInput("")
        → setSending(true)
        → api.chatWithReport(reportId, question, history)
            → POST /api/v1/reports/:id/chat { question, history }
            → returns { answer: "markdown string", disclaimer: "…" }
        → setMessages([...messages, { role: "assistant", content: res.answer }])
        → scroll to bottom
        → setSending(false)
    │
    ▼
Assistant response renders as <Markdown> in white bubble

Patient can continue asking questions (full history passed each turn).
```

**Problems:** `res.disclaimer` is ignored (hardcoded string used instead). Chat history lost on modal close. No suggested starters. No copy button. No typing animation.

---

### Flow 5: Staff Uploads a Lab Report PDF

```
[Staff Login] → navigate("/staff")
    │
    ▼
[Staff Dashboard] loads:
    ├── useOps() → GET /api/v1/appointments/ops → OpsRow[]
    └── Stats computed client-side from ops array

Staff sees:
    ├── Today's Scheduled Volume: N (appointments today)
    ├── Pending PDF Uploads: N (rows where !has_report)
    ├── Total Orders: N (all unique appointment_ids)
    └── Operations Queue table:
        Patient | Test | When | Report
        ─────────────────────────────
        John D. | CBC  | 2026-06-18 09:00 | [↑ Upload PDF]
        Jane S. | LFT  | 2026-06-18 10:30 | ✓ Report uploaded
        ...

Staff clicks [↑ Upload PDF] for a row:
    → fileRef.current?.click()
    → Native OS file picker opens (accepts .pdf, .png, .jpg, .jpeg)
    │
    ▼
Staff selects file:
    → onChange fires → upload.mutate(file)
    → Button shows "Uploading…" (disabled)
    │
    ▼
upload.mutate(file) fires:
    → api.uploadReport(row.mapping_id, file)
    → POST /api/v1/reports/upload (FormData: mapping_id, file)
    → returns { report_id, status }
    │
    ├── onSuccess:
    │   → setNote("Uploaded — AI processing started.")
    │   → queryClient.invalidateQueries(["ops"])
    │   → Row re-renders: "Report uploaded" (has_report = true)
    │
    └── onError:
        → setNote(error.message | "Upload failed")
```

**Problems:** No drag-and-drop. No progress bar. Note state resets after query invalidation. No way to see AI processing status. No way to re-upload.

---

### Flow 6: Token Expiry During Session

```
[Any page] — user is authenticated, JWT has expired (exp < Date.now())

Path A: Navigation event
    → ProtectedRoute renders
    → getClaims() → exp check fails → clearToken() → null
    → <Navigate to="/login" replace />

Path B: API call returns 401
    → request() helper receives 401 response
    → clearToken()
    → window.location.href = "/login"   ← hard redirect (page reload, React state lost)

Both paths result in the user reaching /login.
```

**Problem:** Hard redirect on 401 loses all in-memory state (unsent form data, open modal, chat history). A soft redirect via React Router would be better.

---

## 11. State Map

### Global State (React Context)

| State | Location | Type | Scope |
|-------|---------|------|-------|
| `claims` | `AuthContext` | `Claims \| null` | App-wide |
| `isStaff` | `AuthContext` | `boolean` | App-wide |

### Server State (React Query)

| Query Key | Data | Stale Time | Polling | Used In |
|-----------|------|-----------|---------|---------|
| `["lab-tests"]` | `LabTest[]` | 30s | No | BookingWorkspace |
| `["patients"]` | `PatientProfile[]` | 30s | No | BookingWorkspace |
| `["reports"]` | `Report[]` | 30s | Yes — 4s while processing | PatientDashboard |
| `["ops"]` | `OpsRow[]` | 30s | No | StaffDashboard |
| `["appointments"]` | (invalidated only, never read directly) | — | No | BookingWorkspace (mutation) |

### Local Component State

| State Variable | Component | Purpose |
|---------------|-----------|---------|
| `previewReport` | PatientDashboard | Which report is open in the modal |
| `patientId` | BookingWorkspace | Selected patient profile |
| `selectedTests` | BookingWorkspace | Set of selected test IDs |
| `date` | BookingWorkspace | Appointment date |
| `slot` | BookingWorkspace | Time slot |
| `showProfileForm` | BookingWorkspace | Shows/hides inline profile form |
| `profile` | BookingWorkspace | New profile form values |
| `feedback` | BookingWorkspace | Success/error message |
| `note` (per-row) | OpsRowItem | Upload success/error message |
| `pdfUrl` | ReportPreviewModal | Presigned PDF URL |
| `pdfLoading` | ReportPreviewModal | PDF fetch in progress |
| `panel` | ReportPreviewModal | "summary" or "chat" |
| `messages` | ReportPreviewModal | Chat history array |
| `input` | ReportPreviewModal | Chat input value |
| `sending` | ReportPreviewModal | Chat request in flight |
| `chatError` | ReportPreviewModal | Last chat error |
| `email` | Login | Email input |
| `password` | Login | Password input |
| `error` | Login | Auth error message |
| `submitting` | Login | Login request in flight |

---

## 12. Dead Code

### `ReportChatModal.tsx` — Never Rendered

**File:** `frontend/src/components/ReportChatModal.tsx`
**Status:** Fully implemented, exported, never imported by any file
**Action Required:** Delete

#### Verification

Searching all `.tsx` files in `frontend/src/` for `ReportChatModal` yields:
- `components/ReportChatModal.tsx` — definition only
- No `import` of `ReportChatModal` anywhere in the codebase

#### Why It Should Be Deleted (Not Just Ignored)

1. Adds dead weight to the JavaScript bundle
2. Future developers will read it and assume it is in use somewhere, wasting investigation time
3. The chat implementation in `ReportChatModal` handles the `disclaimer` field from the API response correctly — this creates a confusing discrepancy with `ReportPreviewModal` which ignores the `disclaimer` from the response and uses a hardcoded string
4. Any future changes to chat behavior will create divergence unless this is deleted

---

### Unused API Methods

| Method | Reason Exists | Action |
|--------|--------------|--------|
| `listMyAppointments()` | Appointment history feature was planned but never built | Build the `/app/appointments` page and use it |
| `updateAppointmentStatus()` | Status management was planned but never wired | Build status dropdown in staff queue |

### Unused Environment Variable

| Variable | Defined In | Used In | Action |
|----------|-----------|---------|--------|
| `VITE_COGNITO_DOMAIN` | `.env.example` | Nowhere in `frontend/src/` | Remove from `.env.example` or use it for OAuth/hosted UI |

---

## Summary Reference Table

| Item | File | Type | Status | Recommendation |
|------|------|------|--------|----------------|
| `/login` | `routes/Login.tsx` | Page | Active | REDESIGN |
| `/` | `routes/PatientDashboard.tsx` | Page | Active | SPLIT → 3 pages |
| `/staff` | `routes/StaffDashboard.tsx` | Page | Active | REDESIGN |
| `Layout` | `routes/Layout.tsx` | Layout | Active | KEEP + evolve |
| `ProtectedRoute` | `routes/ProtectedRoute.tsx` | Guard | Active | KEEP |
| `BookingWorkspace` | `components/BookingWorkspace.tsx` | Component | Active | REWRITE as wizard page |
| `BentoCard` | `components/BentoCard.tsx` | Component | Active | KEEP + extend API |
| `ReportPreviewModal` | `components/ReportPreviewModal.tsx` | Modal | Active | REWRITE as page |
| `ReportChatModal` | `components/ReportChatModal.tsx` | Modal | **Dead code** | **DELETE** |
| `OpsRowItem` | `routes/StaffDashboard.tsx` (inline) | Component | Active | EXTRACT + REDESIGN |
| `Button` | `components/ui/button.tsx` | Primitive | Active | KEEP + add variants |
| `Card` family | `components/ui/card.tsx` | Primitive | Active | KEEP + add CardFooter |
| `useLabTests` | `hooks/useLabTests.ts` | Hook | Active | KEEP |
| `usePatients` | `hooks/usePatients.ts` | Hook | Active | KEEP |
| `useReports` | `hooks/useReports.ts` | Hook | Active | KEEP (polling logic is good) |
| `useOps` | `hooks/useOps.ts` | Hook | Active | KEEP |
| `lib/api.ts` | `lib/api.ts` | API layer | Active | KEEP |
| `lib/auth.ts` | `lib/auth.ts` | Auth util | Active | KEEP |
| `lib/cognito.ts` | `lib/cognito.ts` | Cognito | Active | KEEP |
| `lib/AuthContext.tsx` | `lib/AuthContext.tsx` | Context | Active | KEEP |
| `lib/queryClient.ts` | `lib/queryClient.ts` | Config | Active | KEEP |
| `theme/tokens.ts` | `theme/tokens.ts` | Tokens | Active | KEEP + extend |
| `tailwind.config.ts` | `tailwind.config.ts` | Config | Active | KEEP + extend |
