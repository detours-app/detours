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

Three things explain the gap.

**Asking whether a directory is a git repository launched git.** Every refresh asks the host for git status, and the check that runs first launched a `git` process purely to decide whether the directory was in a repository at all. For a directory nowhere near a repository, which is the ordinary case, that was the single most expensive call in the whole refresh, at 50 to 152 ms depending on the host.

**The helper served one request at a time.** It read a request, handled it to completion, wrote the reply, and only then read the next one. So that git status did not merely cost its own time, it also held up every listing queued behind it. A refresh that touches several folders paid for them strictly one after another.

**A refresh re-listed folders nobody could see.** A folder keeps its loaded contents after it is collapsed, and the refresh fanned out to every folder that had ever been opened. Over a remote host each of those is a round trip spent on something invisible.

**Drawing a row rebuilt its date formatting from scratch.** The list asks every visible row for its formatted date on each redraw, and answering meant constructing a date formatter and decoding the whole settings blob out of stored preferences. A JSON parse plus one of Cocoa's most expensive constructions therefore sat on the path of drawing a single cell, paid once per visible row per redraw, and every refresh triggers a redraw. This one is not remote-specific: it slowed every listing.

Separately, and not on the refresh path but affecting everything remote: the app's concurrency pool has one thread per processor and does not replace a thread that blocks. Waiting for the next frame from a helper is a blocking wait held for as long as a connection is idle, and it was parked on that pool, so every connected host permanently cost the app one of its threads. A standalone measurement on an eight-processor machine confirmed the consequence: eight such waits leave the pool unable to run anything at all, and fewer degrade it in proportion. The host key scan, which waits up to eight seconds on an unresponsive host, and the home directory probe, which every saved host runs at launch, sat on the same pool.

## What changed

- The repository check reads the filesystem instead of launching git, so only a directory that really is in a repository costs anything.
- The helper serves read-only requests in parallel, and runs anything that changes the filesystem as a barrier so mutations still observe, and are observed by, the requests around them in the order the client sent them.
- A manual refresh re-lists the pane root and the folders actually on screen. Collapsed folders are marked stale and re-list when next opened, which is what a refresh after a file operation already did.
- The frame wait, the host key scan, and the home directory probe wait on dispatch queues, which add threads when they block, matching what the host kind probe already did for the same reason.
- Listing dates are formatted with reused machinery, rebuilt only when the user changes a date format.
- Every stage of the remote listing pipeline reports its own timing, at a level that costs nothing until someone streams it, with the headline total of each user-initiated refresh recorded so it can be read back afterwards.

To watch a refresh live:

```bash
log stream --level debug --predicate 'subsystem == "com.detours" AND category == "remote-timing"'
```

Streaming the per-stage detail is itself expensive enough to distort the very timings being measured, which is why the end-to-end total is recorded separately and survives without a stream attached.

## Verification status

The two helper-side changes are proved. The app-side ones are not.

Measured from Foundry against the live Linux host `devtest`, comparing the previously deployed helper with the rebuilt one:

| Measurement | Before | After |
| --- | ---: | ---: |
| Git status on a directory outside any repository | 51.65 ms | 0.94 ms |
| Quick listing sent behind a slow folder size | waited for it | answered first, 4 of 4 runs |

That is a 55-fold reduction on the call every refresh makes, and the helper no longer serves one request at a time.

The app-side changes, the refresh fan-out, the date formatting, and the three blocking waits, are verified only by compiling and linting. Proving them needs the changed source on Foundry, and the git origin is unavailable.

Two things got in the way, in sequence. The Proxmox host atticus sleeps from 00:00 to 06:00 and carries Forgejo, the Linux test host, and the container build host, so working past midnight took the git origin, the test target, and the helper build machine away together. They came back at 06:03.

Forgejo did not. The VM reboots out of that sleep window rather than resuming, and `forgejo.service` is `disabled`, with no `multi-user.target.wants` link, so it does not start with the machine. That is worth fixing on the infrastructure side: the git server is down every morning until someone starts it by hand. It could not be started from here, as there is no passwordless sudo on alcazar and Doppler needs Marco present for Touch ID.

What is confirmed: every target and the test target compile clean with no warnings, and the linter is clean.

What is outstanding, in order:

1. Start `forgejo.service` on alcazar and enable it, so the git origin survives the nightly sleep window.
2. Push, then fast-forward Foundry, and run the test suite there, including the new coverage for repository detection and for a quick listing overtaking a slow request on the helper.
3. Re-measure a manual refresh against a live host and compare against the 262 to 333 ms recorded above.
4. Build and install on Spectre, once the above is green. **Until that happens the helper changes are not live on kali-vienna**, because the app deploys the helper it carries in its bundle.

The Linux helper itself is already rebuilt with the fixes, cross-built through the container host, and is what the measurements above were taken against.

## Known remaining work

File transfers do their blocking reads directly on a concurrency pool thread, holding it for the duration of the transfer. This is the same defect as the three that were fixed and would make the whole app sluggish while copying, but it is off the refresh path and was left alone rather than adding an unverifiable change.

Reconciling a listing into the outline costs about 10 ms regardless of how few entries it holds, which is more than it should be and was not investigated.
