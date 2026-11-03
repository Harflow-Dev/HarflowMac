# S02 ordinary application captures

These are unmodified JPEG bytes returned by CUA, captured from the isolated app
window. They use app 0.0.9 and real qualified engine 0.0.7 with generated synthetic
state. They do not establish real provider execution or approval delivery.
[Manifest](manifest.json) records hashes, sizes and state descriptions.

The controlled append appeared in the sidebar after an app-descendant paged read
1.22 seconds after its write, before the earliest possible safety timer. Keyboard
observations: Cmd-N opened New Session, Control-Tab moved focus from its multiline
editor to Name, Escape cancelled, and Cmd-W closed Settings. Tab itself inserted
a tab in the editor. No session was started and no system settings were changed.

Primary and specialist pixel review found readable light/dark task and workflow
content and normal window composition. Scrolling revealed the New Session lower
controls, the last Harnesses card, the workflow inspector bottom and the End
palette item. Edge items can be partially clipped before scrolling.

Native Window → Move & Resize → Top Left produced constrained captures of
2002×1346 pixels. Source declares a 1000×620 minimum content frame; the exact
content rectangle was not independently measured. Canvas, zoom controls and
palette remain separate in these pixels. This is distinct from the older hosted
fixture's unconstrained height growth and history-error overlay.

The initial start screen retains a red connecting indicator despite ready public
pages; switching to task/workflow produces Connected. That reproducible startup
finding remains under investigation. AX and bounded keyboard observations are not
spoken VoiceOver certification or complete accessibility coverage. No visible
credentials or personal home paths were found by visual review; that was not a
forensic metadata audit. All notification flags remained off.
