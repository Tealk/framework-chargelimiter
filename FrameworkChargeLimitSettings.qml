import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "frameworkChargeLimit"

    StyledText {
        width: parent.width
        text: I18n.trFor("frameworkChargeLimit", "Framework Charge Limit")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("frameworkChargeLimit", "The limit is written through the Framework EC, which needs root. See the README for the setup that avoids a password prompt.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "privilegeMode"
        label: I18n.trFor("frameworkChargeLimit", "Privilege mode")
        description: I18n.trFor("frameworkChargeLimit", "pkexec asks for a password through the polkit agent. sudo -n needs the NOPASSWD rule from contrib/; the plugin then uses the installed wrapper on its own.")
        options: [{
                "label": I18n.trFor("frameworkChargeLimit", "pkexec (password prompt)"),
                "value": "pkexec"
            }, {
                "label": I18n.trFor("frameworkChargeLimit", "sudo -n (sudoers rule)"),
                "value": "sudoers"
            }]
        defaultValue: "pkexec"
    }

    StringSetting {
        settingKey: "toolPath"
        label: I18n.trFor("frameworkChargeLimit", "framework_tool path")
        description: I18n.trFor("frameworkChargeLimit", "Leave empty to use framework_tool or framework-tool from PATH. In sudo -n mode the plugin prefers framework-charge-limit from PATH or /usr/local/bin. Only set this for a different location.")
        placeholder: "/usr/bin/framework_tool"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "togglePreset"
        label: I18n.trFor("frameworkChargeLimit", "Preset for the on/off toggle")
        description: I18n.trFor("frameworkChargeLimit", "Limit that the Control Center tile switches to when it is turned on.")
        defaultValue: 80
        minimum: 25
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: I18n.trFor("frameworkChargeLimit", "Refresh interval")
        description: I18n.trFor("frameworkChargeLimit", "Seconds between status reads. 0 disables polling. Reads use sysfs when the kernel exposes the limit, so they do not ask for a password.")
        defaultValue: 300
        minimum: 0
        maximum: 3600
        unit: "s"
    }

    ToggleSetting {
        settingKey: "showPercentInPill"
        label: I18n.trFor("frameworkChargeLimit", "Show percentage in the bar")
        description: I18n.trFor("frameworkChargeLimit", "Draw the limit next to the icon.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showToasts"
        label: I18n.trFor("frameworkChargeLimit", "Notify after changing the limit")
        defaultValue: true
    }
}
