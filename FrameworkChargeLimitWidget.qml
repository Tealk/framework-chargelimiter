import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.Plugins
import Quickshell.Io

PluginComponent {
    id: root

    readonly property int minLimit: 25
    readonly property int maxLimit: 100
    readonly property var presetValues: [maxLimit, 80, 60]

    readonly property string privilegeMode: pluginData.privilegeMode ?? "pkexec"
    readonly property string toolOverride: (pluginData.toolPath ?? "").trim()
    readonly property int refreshInterval: pluginData.refreshInterval ?? 300
    readonly property bool showPercentInPill: pluginData.showPercentInPill ?? true
    readonly property bool showToasts: pluginData.showToasts ?? true
    readonly property int togglePreset: Math.min(maxLimit, Math.max(minLimit, pluginData.togglePreset ?? 80))

    property string detectedTool: ""
    property string detectedWrapper: ""

    // In sudo -n mode the sudoers rule targets the wrapper, so the wrapper takes
    // precedence over framework_tool.
    readonly property string toolPath: {
        if (toolOverride !== "")
            return toolOverride;
        if (privilegeMode === "sudoers" && detectedWrapper !== "")
            return detectedWrapper;
        return detectedTool;
    }

    readonly property bool wrapperMissing: privilegeMode === "sudoers" && toolOverride === "" && detectedWrapper === ""
    property bool toolMissing: false

    // Bar widget, Control Center tile and Control Center detail page are separate
    // instances of this plugin. PluginService.globalVars is shared and reactive
    // across all of them.
    readonly property int sharedLimit: {
        const globals = PluginService.globalVars[pluginId];
        const value = globals ? Number(globals.chargeLimit) : -1;
        return value >= minLimit && value <= maxLimit ? value : -1;
    }

    readonly property int currentLimit: sharedLimit

    readonly property int batteryPercent: BatteryService.batteryAvailable ? Math.round(BatteryService.batteryLevel) : -1
    property int pendingLimit: 80
    property int previousLimit: -1
    property bool busy: false
    property string lastError: ""
    property bool popoutOpen: false

    readonly property string resultFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/dms-framework-charge-limit.result"

    function shellQuote(text) {
        return "'" + String(text).replace(/'/g, "'\\''") + "'";
    }

    function handlePkexecResult(text, quiet) {
        const lines = (text || "").trim().split("\n");
        const code = parseInt(lines[lines.length - 1], 10);
        const out = lines.slice(0, -1).join("\n");
        const limit = parseMaxPercent(out);

        if (code === 0 && limit >= 0) {
            // The limit reported by the EC wins over the requested one.
            setCurrentLimit(limit);
            if (showToasts && quiet !== true)
                ToastService.showInfo(I18n.trFor("frameworkChargeLimit", "Charge limit"), I18n.trFor("frameworkChargeLimit", "Charging stops at %1%").arg(limit));
            return;
        }

        if (previousLimit >= minLimit)
            setCurrentLimit(previousLimit);
        lastError = describeFailure(code, "", out);
        if (quiet !== true)
            ToastService.showError(I18n.trFor("frameworkChargeLimit", "Charge limit not changed"), lastError);
    }

    readonly property bool limitKnown: currentLimit >= 0
    readonly property bool limitEnabled: currentLimit > 0 && currentLimit < maxLimit
    readonly property bool dirty: !limitKnown || pendingLimit !== currentLimit
    readonly property bool ready: !toolMissing && !wrapperMissing && toolPath !== ""

    readonly property string statusText: !limitKnown
                                              ? I18n.trFor("frameworkChargeLimit", "Unknown")
                                          : limitEnabled
                                              ? I18n.trFor("frameworkChargeLimit", "Stops at %1%").arg(currentLimit)
                                              : I18n.trFor("frameworkChargeLimit", "Charges to 100%")

    function commandFor(args) {
        const tool = toolPath !== "" ? toolPath : "framework_tool";
        if (privilegeMode === "sudoers")
            return ["sudo", "-n", tool].concat(args);
        return ["pkexec", tool].concat(args);
    }

    // Proc.runCommand returns stdout only. stderr is folded in to keep the error
    // messages of sudo and framework_tool.
    function commandCapturingStderr(args) {
        const quoted = commandFor(args).map(arg => shellQuote(arg)).join(" ");
        return ["sh", "-c", quoted + " 2>&1"];
    }

    function detectTool() {
        // framework_tool from PATH plus the sudoers wrapper, which is installed
        // outside PATH.
        const probe = "printf 'tool=%s\\nwrapper=%s\\n' " +
                      "\"$(command -v framework_tool 2>/dev/null || command -v framework-tool 2>/dev/null)\" " +
                      "\"$(command -v framework-charge-limit 2>/dev/null || " +
                      "{ [ -x /usr/local/bin/framework-charge-limit ] && echo /usr/local/bin/framework-charge-limit; })\"";
        Proc.runCommand("frameworkChargeLimit.detect", ["sh", "-c", probe], (stdout, code) => {
            const text = stdout || "";
            const toolMatch = /^tool=(.+)$/m.exec(text);
            const wrapperMatch = /^wrapper=(.+)$/m.exec(text);
            root.detectedTool = toolMatch ? toolMatch[1].trim() : "";
            root.detectedWrapper = wrapperMatch ? wrapperMatch[1].trim() : "";
            root.toolMissing = root.detectedTool === "" && root.toolOverride === "" && root.detectedWrapper === "";
            root.refreshStatus(false);
        }, 0, undefined, root);
    }

    function parseMaxPercent(text) {
        const match = /Maximum\s+(\d+)\s*%/.exec(text || "");
        return match ? parseInt(match[1], 10) : -1;
    }

    function setCurrentLimit(value) {
        if (value < minLimit || value > maxLimit)
            return;
        if (sharedLimit !== value)
            PluginService.setGlobalVar(pluginId, "chargeLimit", value);
        PluginService.savePluginState(pluginId, "lastKnownLimit", value);
    }

    onCurrentLimitChanged: pendingLimit = currentLimit

    Component.onCompleted: {
        detectTool();

        // Applies the result of a detached write whose instance is gone.
        startupConsume.running = true;

        // Instances that already share a value skip the state file.
        if (sharedLimit >= minLimit)
            return;
        const cached = Number(PluginService.loadPluginState(pluginId, "lastKnownLimit", -1));
        if (!isNaN(cached) && cached >= minLimit && cached <= maxLimit)
            setCurrentLimit(cached);
    }

    function refreshStatus(userInitiated) {
        if (busy)
            return;
        // A status read needs root as well. pkexec mode reads only on request.
        if (userInitiated === true || privilegeMode !== "pkexec")
            readLimitPrivileged();
    }

    function readLimitPrivileged() {
        if (busy || !ready)
            return;
        busy = true;
        lastError = "";
        Proc.runCommand("frameworkChargeLimit.read", commandFor(["--charge-limit"]),
                        (stdout, code) => root.readLimitFinished(code, stdout), 0, undefined, root);
    }

    function readLimitFinished(code, stdout) {
        busy = false;
        const limit = parseMaxPercent(stdout);
        if (limit >= 0) {
            setCurrentLimit(limit);
            return;
        }
        lastError = describeFailure(code, "", stdout);
    }

    function setLimit(value) {
        if (busy)
            return;
        if (!ready) {
            lastError = setupHint;
            return;
        }
        const limit = Math.round(Math.min(maxLimit, Math.max(minLimit, value)));

        if (privilegeMode === "pkexec") {
            // pkexec runs detached so the polkit dialog outlives the popout. The
            // shell writes stdout and the exit code to resultFile. The limit is
            // applied immediately and rolled back when authorization fails.
            lastError = "";
            previousLimit = currentLimit;
            setCurrentLimit(limit);
            resultPoll.running = false;
            resultPoll.left = 120;
            Quickshell.execDetached(["sh", "-c",
                "rm -f " + shellQuote(resultFile) + "; " +
                "out=$(pkexec " + shellQuote(toolPath !== "" ? toolPath : "framework_tool") +
                " --charge-limit " + limit + " 2>&1); code=$?; " +
                "printf '%s\\n%d\\n' \"$out\" \"$code\" > " + shellQuote(resultFile)]);
            resultPoll.running = true;
            return;
        }

        busy = true;
        lastError = "";
        Proc.runCommand("frameworkChargeLimit.write", commandCapturingStderr(["--charge-limit", String(limit)]),
                        (stdout, code) => root.writeFinished(code, stdout), 0, 20000, root);
    }

    function writeFinished(code, stdout) {
        busy = false;
        const limit = parseMaxPercent(stdout);
        if (limit >= 0) {
            setCurrentLimit(limit);
            if (showToasts)
                ToastService.showInfo(I18n.trFor("frameworkChargeLimit", "Charge limit"), I18n.trFor("frameworkChargeLimit", "Charging stops at %1%").arg(limit));
            return;
        }
        const message = describeFailure(code, "", stdout);
        lastError = message;
        ToastService.showError(I18n.trFor("frameworkChargeLimit", "Charge limit not changed"), message);
        refreshStatus(false);
    }

    function describeFailure(code, errText, outText) {
        const err = (errText || "").trim();
        const out = (outText || "").trim();
        const combined = (err + "\n" + out).trim();

        if (code === 126)
            return I18n.trFor("frameworkChargeLimit", "Authorization was dismissed or no polkit agent is running.");
        if (code === 127)
            return I18n.trFor("frameworkChargeLimit", "The command could not be run. Check the framework_tool path in the plugin settings.");
        if (/no authentication agent/i.test(combined))
            return I18n.trFor("frameworkChargeLimit", "polkit reported no authentication agent. The Dux Shell polkit agent must be enabled, or use the sudoers mode.");
        if (/password is required/i.test(combined))
            return I18n.trFor("frameworkChargeLimit", "sudo asked for a password. Install the sudoers rule from contrib/ or switch the privilege mode to pkexec.");
        if (/not authorized|not permitted|authentication/i.test(combined))
            return I18n.trFor("frameworkChargeLimit", "Authorization failed.");

        const lines = combined.split("\n").filter(line => line.trim() !== "");
        if (lines.length > 0)
            return lines[0].trim();
        return I18n.trFor("frameworkChargeLimit", "Command failed with exit code %1.").arg(code);
    }

    readonly property string setupHint: wrapperMissing
                                            ? I18n.trFor("frameworkChargeLimit", "The sudoers wrapper is missing. Install contrib/framework-charge-limit to /usr/local/bin or set its path in the plugin settings.")
                                        : toolMissing
                                            ? I18n.trFor("frameworkChargeLimit", "framework_tool was not found. Install framework-system or set its path in the plugin settings.")
                                        : ""

    readonly property string pillIcon: !ready
                                           ? "battery_unknown"
                                       : !limitKnown
                                           ? "battery_unknown"
                                       : limitEnabled
                                           ? "battery_saver"
                                           : "battery_charging_full"

    readonly property string pillLabel: !limitKnown ? "–" : String(currentLimit) + "%"

    ccWidgetIcon: pillIcon
    ccWidgetPrimaryText: I18n.trFor("frameworkChargeLimit", "Charge Limit")
    ccWidgetSecondaryText: statusText
    ccWidgetIsActive: ready && limitEnabled
    ccWidgetIsToggle: true
    ccDetailHeight: 320
    ccDetailContent: Component {
        Column {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                width: parent.width
                text: I18n.trFor("frameworkChargeLimit", "Battery charge limit")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: root.statusText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            DSlider {
                id: ccSlider
                width: parent.width
                size: "m"
                minimum: root.minLimit
                maximum: root.maxLimit
                unit: "%"
                enabled: root.ready
                Accessible.name: I18n.trFor("frameworkChargeLimit", "Charge limit")
                onSliderValueChanged: newValue => root.pendingLimit = Math.round(newValue)

                Binding on value {
                    value: root.pendingLimit
                    when: !ccSlider.isDragging
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.presetValues

                    DButton {
                        required property int modelData
                        text: modelData + "%"
                        enabled: root.ready && !root.busy
                        onClicked: root.setLimit(modelData)
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.lastError !== ""
                text: root.lastError
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
                wrapMode: Text.WordWrap
            }
        }
    }

    onCcWidgetToggled: root.toggle()

    onPopoutOpenChanged: {
        if (popoutOpen)
            refreshStatus(false);
    }

    function toggle() {
        if (busy)
            return;
        if (!limitKnown) {
            refreshStatus(true);
            return;
        }
        setLimit(limitEnabled ? maxLimit : togglePreset);
    }

    Timer {
        id: resultPoll
        property int left: 0
        interval: 500
        repeat: true
        running: false
        onTriggered: {
            if (left <= 0) {
                // No answer in time. The applied value stays.
                running = false;
                return;
            }
            left--;
            resultRead.running = true;
        }
    }

    Process {
        id: resultRead
        running: false
        // resultFile exists only after pkexec has exited. Reading in
        // onStreamFinished guarantees that stdout is collected.
        command: ["sh", "-c", "cat " + root.shellQuote(root.resultFile) + " 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = (this.text || "").trim();
                if (text === "")
                    return;
                resultPoll.running = false;
                root.handlePkexecResult(text, false);
            }
        }
    }

    Process {
        id: startupConsume
        running: false
        // Applies a result file left behind by a detached write, then removes it
        // so an old value cannot override later reads.
        command: ["sh", "-c", "f=" + root.shellQuote(root.resultFile) +
            "; [ -f \"$f\" ] && { cat \"$f\"; rm -f \"$f\"; } || true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = (this.text || "").trim();
                if (text !== "")
                    root.handlePkexecResult(text, true);
            }
        }
    }

    Timer {
        id: pollTimer
        interval: Math.max(30, root.refreshInterval) * 1000
        running: root.refreshInterval > 0 && root.surfaceLive !== false
        repeat: true
        onTriggered: root.refreshStatus(false)
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.limitEnabled ? Theme.primary : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.showPercentInPill
                text: root.pillLabel
                font.pixelSize: root.textSize
                color: root.limitEnabled ? Theme.primary : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.limitEnabled ? Theme.primary : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.showPercentInPill
                text: root.pillLabel
                font.pixelSize: root.textSize
                color: root.limitEnabled ? Theme.primary : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 400
    popoutHeight: 430
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor("frameworkChargeLimit", "Charge Limit")
            detailsText: root.statusText
            showCloseButton: true

            Binding {
                target: root
                property: "popoutOpen"
                value: popout.parentPopout ? popout.parentPopout.shouldBeVisible : false
            }

            Item {
                width: parent.width
                implicitHeight: popoutColumn.implicitHeight

                Column {
                    id: popoutColumn
                    width: parent.width
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DIcon {
                            name: root.pillIcon
                            size: Theme.iconSizeLarge
                            color: root.limitEnabled ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXXS

                            StyledText {
                                text: root.limitKnown ? I18n.trFor("frameworkChargeLimit", "Current limit: %1%").arg(root.currentLimit)
                                                      : I18n.trFor("frameworkChargeLimit", "Current limit: unknown")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                text: root.batteryPercent >= 0 ? I18n.trFor("frameworkChargeLimit", "Battery: %1%").arg(root.batteryPercent)
                                                               : I18n.trFor("frameworkChargeLimit", "Battery: unknown")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceVariant
                    }

                    DSlider {
                        id: popoutSlider
                        width: parent.width
                        size: "m"
                        minimum: root.minLimit
                        maximum: root.maxLimit
                        unit: "%"
                        enabled: root.ready && !root.busy
                        Accessible.name: I18n.trFor("frameworkChargeLimit", "Charge limit")
                        onSliderValueChanged: newValue => root.pendingLimit = Math.round(newValue)

                        Binding on value {
                            value: root.pendingLimit
                            when: !popoutSlider.isDragging
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.presetValues

                            DButton {
                                required property int modelData
                                text: modelData + "%"
                                enabled: root.ready && !root.busy
                                onClicked: root.setLimit(modelData)
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DButton {
                            text: I18n.trFor("frameworkChargeLimit", "Apply")
                            iconName: "check"
                            backgroundColor: Theme.primaryContainer
                            textColor: Theme.onPrimaryContainer
                            enabled: root.ready && !root.busy && root.dirty
                            onClicked: root.setLimit(root.pendingLimit)
                        }

                        DButton {
                            text: I18n.trFor("frameworkChargeLimit", "Reload")
                            iconName: "refresh"
                            enabled: !root.busy
                            onClicked: root.refreshStatus(true)
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: root.setupHint !== ""
                        text: root.setupHint
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        width: parent.width
                        visible: root.lastError !== ""
                        text: root.lastError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
