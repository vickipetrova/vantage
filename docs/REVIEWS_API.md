# The customer reviews API

Verified against Apple's documentation on 2026-08-20. Read this before touching `ReviewDecoder` or
`ASCReviewsClient`.

Like `REPORT_FORMAT.md`, this exists because several facts here are only discoverable by trying,
and because a few of them are widely repeated without being documented by Apple at all. Where that
is the case this file says so rather than restating folklore as fact.

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

## Roles: what the docs actually say

Reading reviews needs a different role from downloading sales reports, and replying needs a
different one again. That is the whole reason Vantage holds two keys.

| Task | Roles Apple grants it to |
|---|---|
| View ratings and reviews | Account Holder, Admin, App Manager, Developer, Marketing, Customer Support |
| Respond to customer reviews | Account Holder, Admin, Customer Support |
| Sales and Trends reports | Account Holder, Admin, Finance, Sales — and App Manager, Developer or Marketing **with the Access To Reports permission added** |

Sources: [Apple's role matrix](https://developer.apple.com/help/account/manage-your-team/roles/),
[Respond to reviews](https://developer.apple.com/help/app-store-connect/monitor-ratings-and-reviews/respond-to-reviews/)
("Required role: Account Holder, Admin or Customer Support"), and the
[`UserRole`](https://developer.apple.com/documentation/appstoreconnectapi/userrole) enum.

So **App Manager can read reviews and cannot answer them** — that is what the matrix says, not a
discrepancy in it.

> **A correction, kept deliberately.** An earlier version of this file claimed Apple's role matrix
> and its App Store Connect help page *contradicted* each other about App Manager and replying, and
> three other documents cited that claim as a reason to trust this one. It was wrong. It came from a
> summarised read of the matrix that conflated the "View ratings and reviews" row — where App
> Manager **is** checked — with the "Respond to customer reviews" row, where it is not. Re-checked
> against the raw pages, all three of Apple's sources agree. The design that came out of it is
> unchanged and still right; the justification was not.

### What is genuinely uncertain

These affect what Vantage tells users, and none of them is settled by Apple's published docs:

- **Whether an API key can be given the Customer Support role.** `UserRole` lists
  `CUSTOMER_SUPPORT`, and Apple says "the roles that apply to keys are the same roles that apply to
  users on your team". Community reports say the role is nonetheless unavailable in the key-creation
  UI. Unverified either way here — it needs an authenticated App Store Connect session to check.
- **Whether "Sales and Reports" is a real role name.** It appears in this repo's README and
  SECURITY.md and in a lot of third-party tooling docs, but Apple's `UserRole` enum has no such
  value — there is `SALES`, plus a separate additive `ACCESS_TO_REPORTS` permission. It may well be
  the live UI's wording; it is not Apple's API terminology.
- **Whether an App Manager key really is refused on `POST`.** One unresolved
  [forum report](https://developer.apple.com/forums/thread/800545) (September 2025, no replies) says
  it 403s. That is consistent with the matrix rather than surprising, but it is a single
  uncorroborated data point.

**What Vantage does with all of this:** reading and replying are separated in the type system, not
just the UI. `ASCReviewsClient` reads and has no write methods. `ASCReviewsWriter` is a different
type, constructed only when `Prefs.repliesEnabled` is on *and* a key exists — Swift can't make a
conformance conditional on how a value was built, so the write capability lives in a type that
simply doesn't exist otherwise.

Replying is off by default and behind an explicit consent step naming what an Admin key can do,
because "add a reviews key" must never quietly mean "hand this app full control of your account".

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

**Apple documents no maximum length for `responseBody`** — the field is a plain `string` with no
`maxLength`, and the help pages give no figure. The 5,970-character limit `ReplyValidation` enforces
is **community-tested, not published by Apple**; it is widely cited by ASO tooling, and every source
for it traces back to someone measuring rather than to a document.

It is enforced client-side anyway, because the alternative is discovering the real limit as a 422
after someone has written six thousand characters. If Apple's actual limit is different, the failure
mode is a reply refused locally that would have been accepted — annoying, and better than the
reverse.

### Writing

`POST /v1/customerReviewResponses` body:

```json
{"data":{"type":"customerReviewResponses",
         "attributes":{"responseBody":"…"},
         "relationships":{"review":{"data":{"type":"customerReviews","id":"…"}}}}}
```

201 returns a **single** resource under `data` — not the array-plus-`included` shape a listing
returns. Decoding it with the listing decoder would report a published reply as a failure.

Status codes worth handling separately: **403** is almost always the role (App Manager can read and
cannot answer), **409/422** mean Apple accepted the request and refused the content, and **404** on
a delete means the reply is already gone.

**There is no "already has a reply" error.** `POST` is create-or-update with no distinction and no
signal in the response that anything was overwritten, which is why the confirmation has to say
"Replace" and show the old text — the API will never say it for you.

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
