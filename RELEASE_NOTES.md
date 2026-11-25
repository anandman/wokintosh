# Wokintosh 2.0.2

Collector updates now announce themselves with a native popup, and System readings are easier to distinguish at a glance.

- **Collector update popup.** Choose Review Updates to open Settings → Machines, or Later to keep working with the menu reminder still available. The popup names affected machines, including a local managed observer when needed. New updates can prompt again; acknowledged updates stay quiet across polling and app relaunches. A popup that was never shown is not permanently dismissed.
- **Clearer System readings.** CPU is blue, RAM purple and disk space green, with matching values, bold headings, larger icons and lightly tinted reading panels. USED and FREE are more prominent. RAM remains in GB; disk measurements and usage bars keep their existing meaning.

Install through Sparkle’s **Check for Updates**, or download the signed, notarized Mac app. Update collectors only when Machines says they need it. The collector code is unchanged from 2.0.1, so already-current collectors do not need another installation. Existing iPhone/iPad builds remain compatible and do not need reinstalling. The companion remains source-built with Xcode.

Notification acknowledgements are local to this Mac and stay out of setup exports. Reviewing the popup opens Machines; collector installation still requires your explicit Update action.
