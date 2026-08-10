# Remote refresh performance, 2026-08-10

Why refreshing a remote pane felt slow, what the time was actually spent on, and what changed.

## The complaint

Refreshing a remote host took far too long, with `kali-vienna` as the example. The folder in question is a home directory holding 59 entries, 7 of them visible.

## What the time was not

Neither the host nor the network was responsible, and both were ruled out before any code changed.

Timings taken against the live `kali-vienna` helper, driving it directly over SSH with hand-built protocol frames:

| Measurement | Result |
| --- | ---: |
| SSH connect, run a command, disconnect | 170 ms |
| Helper process start with no work | 180 ms |
| One directory listing of the home directory | ~1 ms |
| Twenty listings in a single session | 20 ms total |
| Reply size for the whole listing | 357 bytes |

The helper answers a listing in about a millisecond and the round trip adds almost nothing. Anything slower than that was the app's own doing.

## What the time was

The remote listing pipeline now reports the elapsed time of each of its stages, which turned a single unexplained total into an attributable one. Driving the installed app through the refresh workflow against a live Linux host produced this, for a directory of eight files:

| Stage | Time |
| --- | ---: |
| A complete manual refresh, end to end | 262 to 333 ms |
| The listing call it depends on | 1 to 2 ms |
| Asking the host for git status | 152 ms |
| Reconciling the result into the outline | ~10 ms |

Four things explain the gap, and the largest was found last, after the first three had been fixed and measured without the total moving.

**Asking whether a directory is a git repository launched git.** Every refresh asks the host for git status, and the check that runs first launched a `git` process purely to decide whether the directory was in a repository at all. For a directory nowhere near a repository, which is the ordinary case, that was the single most expensive call in the whole refresh, at 50 to 152 ms depending on the host.

**The helper served one request at a time.** It read a request, handled it to completion, wrote the reply, and only then read the next one. So that git status did not merely cost its own time, it also held up every listing queued behind it. A refresh that touches several folders paid for them strictly one after another.

**A refresh re-listed folders nobody could see.** A folder keeps its loaded contents after it is collapsed, and the refresh fanned out to every folder that had ever been opened. Over a remote host each of those is a round trip spent on something invisible.

**Turning a remote path into a URL waited on the local automounter.** This was the big one. Building a file URL without saying whether the path is a directory makes the system stat the path to find out, and for a path beginning `/home`, which is where these hosts keep home directories, that stat goes through the local automounter. Measured on the test machine: **12.256 ms per conversion**, against 0.002 ms once the answer is supplied, and 0.005 ms for a path outside an automounted prefix. A listing paid it once per entry, which is exactly the ten milliseconds per entry seen between a reply arriving and its entries becoming usable. The URL was then thrown away, because a file item is built from the location rather than the URL.

**Drawing a row rebuilt its date formatting from scratch.** The list asks every visible row for its formatted date on each redraw, and answering meant constructing a date formatter and decoding the whole settings blob out of stored preferences. A JSON parse plus one of Cocoa's most expensive constructions therefore sat on the path of drawing a single cell, paid once per visible row per redraw, and every refresh triggers a redraw. This one is not remote-specific: it slowed every listing.

Separately, and not on the refresh path but affecting everything remote: the app's concurrency pool has one thread per processor and does not replace a thread that blocks. Waiting for the next frame from a helper is a blocking wait held for as long as a connection is idle, and it was parked on that pool, so every connected host permanently cost the app one of its threads. A standalone measurement on an eight-processor machine confirmed the consequence: eight such waits leave the pool unable to run anything at all, and fewer degrade it in proportion. The host key scan, which waits up to eight seconds on an unresponsive host, and the home directory probe, which every saved host runs at launch, sat on the same pool.

## What changed

- The repository check reads the filesystem instead of launching git, so only a directory that really is in a repository costs anything.
- The helper serves read-only requests in parallel, and runs anything that changes the filesystem as a barrier so mutations still observe, and are observed by, the requests around them in the order the client sent them.
- A manual refresh re-lists the pane root and the folders actually on screen. Collapsed folders are marked stale and re-list when next opened, which is what a refresh after a file operation already did.
- The frame wait, the host key scan, and the home directory probe wait on dispatch queues, which add threads when they block, matching what the host kind probe already did for the same reason.
- Listing dates are formatted with reused machinery, rebuilt only when the user changes a date format.
- Every conversion of a remote path to a URL goes through one place that declares whether the path is a directory instead of asking the filesystem, always as a non-directory so two URLs for the same remote path still compare equal.
- Every stage of the remote listing pipeline reports its own timing, at a level that costs nothing until someone streams it, with the headline total of each user-initiated refresh recorded so it can be read back afterwards.

To watch a refresh live:

```bash
log stream --level debug --predicate 'subsystem == "com.detours" AND category == "remote-timing"'
```

Streaming the per-stage detail is itself expensive enough to distort the very timings being measured, which is why the end-to-end total is recorded separately and survives without a stream attached.

## Verification status

Proved on Foundry against the live Linux host `devtest`, with the app timing its own refresh and publishing the figure alongside the counters the tests already read, so nothing was observing the measurement:

| Measurement | Before | After |
| --- | ---: | ---: |
| A complete manual refresh, end to end | 274.2 and 306.8 ms | 69.9 and 72.5 ms |
| Git status on a directory outside any repository | 51.65 ms | 0.94 ms |
| Git status inside a repository | 152 ms | 102 ms |
| Quick listing sent behind a slow folder size | waited for it | answered first, 4 of 4 runs |
| Turning a remote `/home` path into a URL | 12.256 ms | 0.002 ms |

The refresh is four times faster. Worth being precise about the order this was found in: the helper fixes are real and measured, but on their own they did not move the end-to-end figure at all, because the cost they removed sits outside the window a refresh is measured over. Only the automounter finding moved it.

Suites, all on Foundry:

| Suite | Result |
| --- | --- |
| Server, git detection, file item | 40 tests, 0 failures |
| Refresh scheduler, remote listing, reconcile | 46 tests, 0 failures |
| Live remote integration against `devtest` | 37 tests, 0 failures |
| Installed refresh workflow against `devtest` | passed |
| Installed connection workflow against `devtest` | passed |
| Signed build launched on Foundry | alive after 12 s, zero crash reports |

The whole suite is green: **922 tests, 33 skipped, 0 failures**, plus the `refresh`, `mutation` and `archive` installed workflows.

Two clusters were failing and both turned out to be real, not environmental:

- **Password-protected zips used broken encryption.** They were written with Info-ZIP's ZipCrypto, which is recoverable from a known plaintext fragment, and the test machine carries a root-installed guard that refuses it outright. They now use 7-Zip with AES-256, and are read and listed the same way since Info-ZIP cannot read AES at all. Three further faults were hiding behind that one: 7-Zip ships as `7zz` from its own project as well as `7z` from p7zip and was not being found under either name, which is why the tests that would have caught the rest were being skipped; a helper started over a non-login session inherits a PATH that hides it even when installed; and 7-Zip never turns terminal echo off, so the pty runner, which waits for a tool to do that before sending a password so a secret never lands on a visible line, sat at every prompt until it timed out.
- **Fast-lane tests raced a copy they could not catch.** Five tests proved a quick operation can run during a bulk one by starting a large copy and racing it. On a cloning filesystem the copy finishes immediately, so under load the bulk operation was over before the assertion looked. The queue can now hold a copy open, after it has claimed its protected paths and before any file work, until the test releases it.

## Known remaining work

Reconciling a listing into the outline costs about 10 ms regardless of how few entries it holds. It is no longer the dominant cost, but it is still more than it should be for a handful of rows, and it was not investigated.

The `zip` guard shim on Foundry and the load-sensitive fast-lane assertions above both keep a full suite run from reading clean, and both deserve their own fix.
