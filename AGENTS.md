# TokenUsage repository instructions

- After every change to app source code, resources, `Info.plist`, or build/install scripts, before reporting completion, run `./Scripts/update-installed-app.sh`. Documentation-only and test-only changes do not require reinstalling the app.
- The update script must successfully rebuild the Release app, install it at `/Applications/Token Usage.app`, verify the installed bundle, and relaunch it.
- If macOS or the sandbox requires permission to update `/Applications` or relaunch the app, request that permission instead of skipping the installed-app update.
