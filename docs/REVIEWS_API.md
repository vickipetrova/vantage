# The customer reviews API

Verified against Apple's documentation on 2026-08-20. Read this before touching `ReviewDecoder` or
`ASCReviewsClient`.

Like `REPORT_FORMAT.md`, this exists because Apple's own documentation contradicts itself in at
least one place that matters, and because several facts here are only discoverable by trying.

## The endpoints

| Operation | Route |
|---|---|
| List an app's reviews | `GET /v1/apps/{id}/customerReviews` |
| Read one review | `GET /v1/customerReviews/{id}` |
| Read a review's response | `GET /v1/customerReviews/{id}/response` — **404 when there is none** |
| Create **or update** a response | `POST /v1/customerReviewResponses` |
| Delete a response | `DELETE /v1/customerReviewResponses/{id}` → 204 |

**There is no portfolio-wide endpoint.** Reviews are per app. A view across every app is N requests,
one per app, which is why Vantage fetches them when the Reviews section is opened rather than from
the background poll timer — see `PanelModel.loadReviews`.

### Listing parameters

| Parameter | Values |
|---|---|
| `sort` | `rating`, `-rating`, `createdDate`, `-createdDate` |
| `filter[rating]` | `1`–`5`, comma-joined |
| `filter[territory]` | ISO-3166 alpha-**3** (`USA`, `DEU`) |
| `exists[publishedResponse]` | `true` / `false` |
| `fields[customerReviews]` | `rating`, `title`, `body`, `reviewerNickname`, `createdDate`, `territory`, `response`, `reviewTerritory` |
| `include` | `response`, `reviewTerritory` |
| `limit` | max **200** |

Pagination is JSON:API — `links.next`, `meta.paging.total`.

> **`filter[territory]` is alpha-3 here.** The sales report uses a different form. Do not reuse a
> territory mapping between the two without checking it.

## ⚠️ The role contradiction

**Two Apple pages disagree about who can reply to a review, and both disagree with what actually
happens.**

- [support/roles](https://developer.apple.com/support/roles/) grants *Respond to customer reviews*
  to **Account Holder, Admin, App Manager, Customer Support**.
- [App Store Connect help › Role permissions](https://developer.apple.com/help/app-store-connect/reference/role-permissions/)
  lists only **Account Holder, Admin, Customer Support**.

In practice, for an **API key** rather than a person:

- **Customer Support cannot be assigned to an API key at all**, despite Apple's claim that "the
  roles that apply to keys are the same roles that apply to users on your team."
- **App Manager keys return 403 on `POST /v1/customerReviewResponses`**
  ([forum thread](https://developer.apple.com/forums/thread/800545), and others through 2024).
- **Admin is the only role that reliably works for replying.**

Reading reviews works at App Manager.

**What Vantage does with that:** reading and replying are separated. The Reviews section asks for a
key with the App Manager role and does nothing but read. Replying is a later phase, off by default,
behind an explicit consent step that names what an Admin key can do — because "add a reviews key"
must never quietly mean "hand this app full control of your account".

## Roles, for reference

| Role | Sales reports | Read reviews | Reply |
|---|---|---|---|
| Account Holder | ✓ | ✓ | ✓ |
| Admin | ✓ | ✓ | ✓ |
| App Manager | ✗ | ✓ | **✗ in practice** |
| Sales | ✓ | ✗ | ✗ |
| Finance | ✓ | ✗ | ✗ |
| Customer Support | ✗ | ✓ | ✓ (but not assignable to a key) |

This is why Vantage holds two keys. The sales key stays on Sales and Reports — the minimum that can
read a sales report — and never gains a role it doesn't need just so a second feature can work.

## Response states

`CustomerReviewResponseV1.Attributes` carries `responseBody`, `lastModifiedDate`, and `state`, which
is one of exactly two values:

- `PUBLISHED`
- `PENDING_PUBLISH`

**`PENDING_PUBLISH` is the normal state immediately after replying.** Apple says plainly that
responses do not appear in the App Store instantly, and the same is true of deletions. Rendering
that state as a failure would report every successful reply as an error. `ReviewDecoder` also maps
any *unrecognised* state to `pendingPublish`: if Apple adds a third, claiming a reply is live when
it isn't is the worse of the two mistakes.

Apple documents no maximum length for `responseBody`. The App Store's own limit is 5,970 characters;
enforce it client-side rather than discovering it as a 422.

## Rate limits

```
X-Rate-Limit: user-hour-lim:3500;user-hour-rem:500;
```

Per key, rolling hour, `429` with `RATE_LIMIT_EXCEEDED` on breach. Apple says actual limits vary, so
read the header rather than assuming 3500.

Reviews cost one request per app per refresh, plus pagination. `ReviewStore` is a **TTL cache**, not
an archive — unlike a daily sales report, a review's response can be written, edited or deleted from
App Store Connect's web UI while Vantage isn't looking, so treating reviews as immutable would show
a reply that no longer exists, indefinitely.

## Traps

- **`links.next` is a response body choosing where the next authenticated request goes.** It is
  checked for `https` and Apple's own host before being followed; otherwise a hostile or mistaken
  `next` would carry the bearer token off Apple's infrastructure. Tested.
- **The response is sideloaded.** It arrives in `included`, linked from the review's
  `relationships.response.data.id` — not embedded in the review. A review with no reply has the
  relationship absent entirely.
- **Dates come in two ISO 8601 forms in the same payload**, with and without fractional seconds.
  Both are tried.
- **The Apple ID becomes part of a URL path**, and it arrives from a parsed TSV. It is *validated*
  as wholly digits, never *sanitized* by stripping non-digits — filtering `../../v1/users` yields
  `1`, which defeats the traversal while silently requesting a different real app's reviews.

## Test fixtures

**Every reviewer nickname, title and body in `Tests/` is invented.** Real ones are other people's
data and this repository is public. There is no CI check for this — code review is the control.
