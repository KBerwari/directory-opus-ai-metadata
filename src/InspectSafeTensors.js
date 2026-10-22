function OnInit(initData) {
    initData.name = "SafeTensors Metadata Inspector";
    initData.version = "0.1";
    initData.desc = "Inspect metadata and tensors in the selected SafeTensors file.";
    initData.default_enable = true;
    initData.min_version = "12.21";
    initData.config.PriorityFields = "ss_tag_frequency, modelspec.title, ss_output_name, modelspec.description, " +
        "ss_sd_model_name, ss_base_model_version, modelspec.architecture, ss_datasets, ot_config, " +
        "training_info, ss_steps, ss_epoch, modelspec.resolution";

    var command = initData.AddCommand();
    command.name = "InspectSafeTensors";
    command.method = "OnInspectSafeTensors";
    command.label = "Inspect SafeTensors";
    command.desc = "Show metadata for one selected .safetensors file.";
}

function OnInspectSafeTensors(data) {
    var tab = data.func.sourcetab;
    var dialog = tab.Dlg();
    dialog.template = getDialogXml();
    dialog.Create();
    configureColumns(dialog.Control("metadata"), ["Key", "Value"], [320, 800]);
    configureColumns(dialog.Control("tags"), ["Tag", "Recorded count"], [350, 100]);
    configureColumns(dialog.Control("tensors"), ["Tensor", "Data type", "Shape"], [450, 90, 180]);
    showView(dialog, "metadata");
    dialog.WatchTab(tab, "select,navigate");
    dialog.Show();
    var info = refreshInspector(dialog, tab);

    while (true) {
        var message = dialog.GetMsg();
        if (!message.result) break;
        if (message.event == "tab") {
            if (message.value == "close") {
                dialog.EndDlg();
                break;
            }
            info = refreshInspector(dialog, tab);
        }
        else if (message.event == "click" && message.control == "refresh") {
            info = refreshInspector(dialog, tab);
        }
        else if (message.event == "click" && message.control == "copy") {
            copyText(dialog, String(dialog.Control("summary").value));
        }
        else if (message.event == "click" && /^(metadata|tags|tensors)View$/.test(message.control)) {
            showView(dialog, message.control.replace(/View$/, ""));
        }
        else if ((message.control == "metadata" && message.event == "dblclk") ||
                 (message.event == "click" && (message.control == "openValue" || message.control == "copyValue"))) {
            var item = dialog.Control("metadata").value;
            if (info && item && item.index >= 0 && Object.prototype.hasOwnProperty.call(info.Metadata, String(item.name))) {
                var value = String(info.Metadata[String(item.name)]);
                if (message.control == "copyValue") copyText(dialog, value);
                else showMetadataValue(dialog, String(item.name), value);
            }
        }
    }
}

function copyText(parent, text) {
    try {
        DOpus.SetClip(String(text));
    }
    catch (error) {
        var dialog = DOpus.Dlg();
        dialog.window = parent;
        dialog.title = "Copy failed";
        dialog.message = String(error.message || error.description || error);
        dialog.buttons = "OK";
        dialog.Show();
    }
}

function getMetadataKeys(metadata, priority) {
    var keys = [];
    for (var key in metadata) {
        if (Object.prototype.hasOwnProperty.call(metadata, key)) keys.push(key);
    }
    keys.sort();
    var first = [];
    var fields = priority.split(",");
    for (var i = 0; i < fields.length; i++) {
        var name = fields[i].replace(/^\s+|\s+$/g, "");
        for (var k = 0; k < keys.length; k++) {
            if (keys[k] == name) {
                first.push(keys.splice(k, 1)[0]);
                break;
            }
        }
    }
    return first.concat(keys);
}

function showView(dialog, name) {
    var views = ["metadata", "tags", "tensors"];
    for (var i = 0; i < views.length; i++) {
        dialog.Control(views[i]).visible = views[i] == name;
        dialog.Control(views[i] + "View").enabled = views[i] != name;
    }
    dialog.Control("openValue").enabled = name == "metadata";
    dialog.Control("copyValue").enabled = name == "metadata";
}

function configureColumns(control, names, widths) {
    control.mode = "details";
    control.columns.DeleteColumn(-1);
    for (var i = 0; i < names.length; i++) {
        var index = control.columns.AddColumn(names[i]);
        control.columns.GetColumnAt(index).width = widths[i];
    }
}

function addRow(control, cells) {
    var index = control.AddItem(String(cells[0]));
    var row = control.GetItemAt(index);
    for (var i = 1; i < cells.length; i++) row.subitems(i - 1).text = String(cells[i]);
}

function previewValue(value) {
    var text = String(value).replace(/[\r\n]+/g, " ");
    return text.length > 160 ? text.slice(0, 160) + "..." : text;
}

function showMetadataValue(parent, name, value) {
    var dialog = DOpus.Dlg();
    dialog.window = parent;
    dialog.template = getValueDialogXml();
    dialog.title = name;
    dialog.Create();
    var tree = dialog.Control("tree");
    configureColumns(tree, ["Field", "Value"], [300, 650]);
    var root = null;
    try {
        var parsed = JSON.parse(value);
        if (parsed !== null && typeof parsed == "object") root = { name: name, value: parsed, expanded: true };
    }
    catch (ignored) {}
    var rows = [];
    var text = value;
    tree.visible = root !== null;
    dialog.Control("text").visible = root === null;
    dialog.Control("text").value = value;
    dialog.Control("back").enabled = false;
    dialog.Control("expandAll").enabled = root !== null;
    dialog.Control("collapseAll").enabled = root !== null;
    dialog.Control("hint").visible = root !== null;
    dialog.Show();
    if (root) renderValueTree(tree, root, rows);
    while (true) {
        var message = dialog.GetMsg();
        if (!message.result) break;
        if ((message.control == "tree" && (message.event == "selchange" || message.event == "dblclk")) ||
            (message.event == "click" && (message.control == "expandAll" || message.control == "collapseAll"))) {
            try {
                if (message.control == "expandAll" || message.control == "collapseAll") {
                    setValueExpanded(root, message.control == "expandAll");
                    renderValueTree(tree, root, rows);
                    tree.visible = true;
                    dialog.Control("text").visible = false;
                    dialog.Control("back").enabled = false;
                    text = value;
                    continue;
                }
                var item = tree.value;
                if (!item) continue;
                var index = item.index;
                if (index < 0 || !rows[index]) continue;
                var node = rows[index];
                if (node.value !== null && typeof node.value == "object") {
                    if (message.event != "selchange") continue;
                    node.expanded = !node.expanded;
                    renderValueTree(tree, root, rows);
                }
                else if (message.event == "dblclk") {
                    text = String(node.value);
                    dialog.Control("text").value = text;
                    tree.visible = false;
                    dialog.Control("text").visible = true;
                    dialog.Control("back").enabled = true;
                }
            }
            catch (error) {
                text = "Could not open this entry: " + String(error.message || error.description || error);
                if (error.number) text += " (" + error.number + ")";
                dialog.Control("text").value = text;
                tree.visible = false;
                dialog.Control("text").visible = true;
                dialog.Control("back").enabled = true;
            }
        }
        else if (message.event == "click" && message.control == "back") {
            tree.visible = true;
            dialog.Control("text").visible = false;
            dialog.Control("back").enabled = false;
            text = value;
        }
        else if (message.event == "click" && message.control == "copy") {
            var copiedValue = text;
            if (tree.visible) {
                var selected = tree.value;
                if (selected && selected.index >= 0 && rows[selected.index]) {
                    var selectedNode = rows[selected.index];
                    copiedValue = selectedNode === root ? value :
                        (typeof selectedNode.value == "object" ? JSON.stringify(selectedNode.value, null, 2) : String(selectedNode.value));
                }
            }
            copyText(dialog, copiedValue);
        }
    }
}

function renderValueTree(control, root, rows) {
    rows.length = 0;
    control.redraw = false;
    try {
        control.RemoveItem(-1);
        appendValueNode(control, root, 0, rows);
        control.columns.GetColumnAt(0).width = -1;
        control.columns.GetColumnAt(1).width = Math.max(300, control.cx - control.columns.GetColumnAt(0).width - 24);
        control.columns.GetColumnAt(1).resize = true;
    }
    finally { control.redraw = true; }
}

function appendValueNode(control, node, depth, rows) {
    var branch = node.value !== null && typeof node.value == "object";
    var prefix = branch ? (node.expanded ? "[-] " : "[+] ") : "";
    var preview = branch ? (node.value instanceof Array ? "Array" : "Object") : previewValue(node.value);
    addRow(control, [new Array(depth * 3 + 1).join(" ") + prefix + node.name, preview]);
    rows.push(node);
    if (!branch || !node.expanded) return;
    var children = getValueChildren(node);
    for (var i = 0; i < children.length; i++) appendValueNode(control, children[i], depth + 1, rows);
}

function getValueChildren(node) {
    if (!node.children) {
        node.children = [];
        for (var key in node.value) {
            if (Object.prototype.hasOwnProperty.call(node.value, key)) {
                node.children.push({ name: key, value: node.value[key], expanded: false });
            }
        }
    }
    return node.children;
}

function setValueExpanded(node, expanded) {
    if (!node || node.value === null || typeof node.value != "object") return;
    node.expanded = expanded;
    var children = expanded ? getValueChildren(node) : (node.children || []);
    for (var i = 0; i < children.length; i++) setValueExpanded(children[i], expanded);
}

function getSelectedPath(tab) {
    tab.Update();
    var selected = new Enumerator(tab.selected_files);
    if (selected.atEnd()) throw new Error("Select one .safetensors file.");
    var item = selected.item();
    selected.moveNext();
    if (!selected.atEnd()) throw new Error("Select only one file.");
    var path = String(item.realpath);
    if (!/\.safetensors$/i.test(path)) throw new Error("The selected file is not a .safetensors file.");
    return path;
}

function refreshInspector(dialog, tab) {
    var metadata = dialog.Control("metadata");
    var tags = dialog.Control("tags");
    var tensors = dialog.Control("tensors");
    metadata.RemoveItem(-1);
    tags.RemoveItem(-1);
    tensors.RemoveItem(-1);
    dialog.Control("file").title = "";

    try {
        var path = getSelectedPath(tab);
        dialog.Control("file").title = path;
        dialog.Control("summary").value = "Reading metadata...";
        var info = JSON.parse(runHelper(path));
        dialog.Control("summary").value = buildSummary(info);

        metadata.redraw = false;
        var keys = getMetadataKeys(info.Metadata, String(Script.config.PriorityFields));
        for (var k = 0; k < keys.length; k++) {
            addRow(metadata, [keys[k], previewValue(info.Metadata[keys[k]])]);
        }
        if (!keys.length) addRow(metadata, ["No embedded metadata", ""]);

        tags.redraw = false;
        for (var i = 0; i < info.TrainingTags.length; i++) {
            addRow(tags, [info.TrainingTags[i].Tag, info.TrainingTags[i].Count]);
        }
        if (!info.TrainingTags.length) addRow(tags, ["No recorded tag counts", ""]);

        tensors.redraw = false;
        for (var j = 0; j < info.Tensors.length; j++) {
            var tensor = info.Tensors[j];
            addRow(tensors, [tensor.Name, tensor.DType, tensor.Shape.length ? tensor.Shape.join(" x ") : "Scalar"]);
        }
        return info;
    }
    catch (error) {
        metadata.RemoveItem(-1);
        tags.RemoveItem(-1);
        tensors.RemoveItem(-1);
        dialog.Control("summary").value = String(error.message || error);
    }
    finally {
        metadata.redraw = true;
        tags.redraw = true;
        tensors.redraw = true;
        metadata.columns.AutoSize();
    }
}

function buildSummary(info) {
    var lines = [
        "File: " + info.FilePath,
        "Size: " + (info.SizeBytes / 1048576).toFixed(2) + " MiB",
        "Tensors: " + info.TensorCount,
        ""
    ];
    if (!info.HasMetadata) {
        lines.push("No embedded metadata found.");
    }
    else {
        var fields = [
            ["Title", "Title"],
            ["Description", "Description"],
            ["Base model", "BaseModel"],
            ["Model version", "BaseModelVersion"],
            ["Architecture", "Architecture"],
            ["Resolution", "Resolution"],
            ["Training steps", "TrainingSteps"],
            ["Epoch", "TrainingEpoch"],
            ["Trigger phrase", "TriggerPhrase"],
            ["Usage hint", "UsageHint"],
            ["Model tags", "ModelTags"],
            ["Software", "Software"]
        ];
        for (var i = 0; i < fields.length; i++) {
            var value = info[fields[i][1]];
            lines.push(fields[i][0] + ": " + (value === null || value === undefined || value === "" ? "Not recorded" : String(value)));
        }
    }
    if (info.Warnings.length) lines.push("", "Warnings:", info.Warnings.join("\r\n"));
    return lines.join("\r\n");
}

function runHelper(path) {
    var files = new ActiveXObject("Scripting.FileSystemObject");
    var helper = files.BuildPath(files.GetParentFolderName(String(Script.file)), "Get-SafeTensorMetadata.ps1");
    if (!files.FileExists(helper)) {
        throw new Error("Copy Get-SafeTensorMetadata.ps1 into the same folder as this add-in.");
    }

    var shell = new ActiveXObject("WScript.Shell");
    var powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    var temporary = files.GetSpecialFolder(2);
    var outputPath = files.BuildPath(temporary, files.GetTempName());
    var errorPath = files.BuildPath(temporary, files.GetTempName());
    var script = "$ErrorActionPreference = 'Stop'; try { & " + quotePowerShell(helper) +
        " -Path " + quotePowerShell(path) + " -TensorList -Format Json | Set-Content -LiteralPath " +
        quotePowerShell(outputPath) + " -Encoding UTF8; exit 0 } catch { " +
        "[System.IO.File]::WriteAllText(" + quotePowerShell(errorPath) +
        ", $_.Exception.Message, [System.Text.Encoding]::UTF8); exit 1 }";

    try {
        // Encoding avoids an extra shell and preserves Unicode paths.
        var command = '"' + powershell + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + encodeCommand(script);
        var exitCode = shell.Run(command, 0, true);
        if (exitCode !== 0) {
            var detail = files.FileExists(errorPath) ? readUtf8(errorPath) : "PowerShell exited with code " + exitCode + ".";
            throw new Error(detail);
        }
        var output = readUtf8(outputPath);
        if (!output.replace(/\s/g, "")) throw new Error("The metadata helper returned no output.");
        return output;
    }
    finally {
        try { if (files.FileExists(outputPath)) files.DeleteFile(outputPath); } catch (ignored) {}
        try { if (files.FileExists(errorPath)) files.DeleteFile(errorPath); } catch (ignored) {}
    }
}

function quotePowerShell(value) {
    return "'" + String(value).replace(/'/g, "''") + "'";
}

function encodeCommand(text) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2;
    stream.Charset = "unicode";
    stream.Open();
    try {
        stream.WriteText(text);
        stream.Position = 0;
        stream.Type = 1;
        stream.Position = 2; // Skip the UTF-16 byte-order mark.
        var document = new ActiveXObject("MSXML2.DOMDocument.6.0");
        var element = document.createElement("command");
        element.dataType = "bin.base64";
        element.nodeTypedValue = stream.Read();
        return element.text.replace(/\s/g, "");
    }
    finally {
        stream.Close();
    }
}

function readUtf8(path) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2;
    stream.Charset = "utf-8";
    stream.Open();
    try {
        stream.LoadFromFile(path);
        return String(stream.ReadText()).replace(/^\uFEFF/, "");
    }
    finally {
        stream.Close();
    }
}

function getDialogXml() {
    return [
        '<dialog fontsize="8" height="508" lang="english" resize="yes" title="SafeTensors Inspector" width="720">',
        '<control height="10" name="file" resize="w" type="static" width="708" x="6" y="6" />',
        '<control height="90" multiline="yes" name="summary" readonly="yes" resize="w" type="edit" width="708" x="6" y="20" />',
        '<control height="14" name="metadataView" title="Metadata" type="button" width="70" x="6" y="116" />',
        '<control height="14" name="tagsView" title="Tag counts" type="button" width="70" x="82" y="116" />',
        '<control height="14" name="tensorsView" title="Tensors" type="button" width="70" x="158" y="116" />',
        '<control fullrow="yes" height="344" name="metadata" resize="wh" type="listview" width="708" x="6" y="136" />',
        '<control fullrow="yes" height="344" name="tags" resize="wh" type="listview" visible="no" width="708" x="6" y="136" />',
        '<control fullrow="yes" height="344" name="tensors" resize="wh" type="listview" visible="no" width="708" x="6" y="136" />',
        '<control height="14" name="refresh" resize="y" title="Refresh" type="button" width="55" x="6" y="488" />',
        '<control height="14" name="copy" resize="y" title="Copy summary" type="button" width="75" x="67" y="488" />',
        '<control height="14" name="copyValue" resize="y" title="Copy metadata value" type="button" width="100" x="148" y="488" />',
        '<control height="14" name="openValue" resize="y" title="Open value" type="button" width="70" x="254" y="488" />',
        '<control close="1" height="14" name="close" resize="xy" title="Close" type="button" width="55" x="659" y="488" />',
        '</dialog>'
    ].join("");
}

function getValueDialogXml() {
    return [
        '<dialog fontsize="8" height="420" lang="english" resize="yes" title="Metadata value" width="640">',
        '<control height="10" name="hint" resize="w" title="Click a group to fold or unfold it. Double-click a value to read it in full." type="static" width="628" x="6" y="6" />',
        '<control fullrow="yes" height="372" name="tree" nosortheader="yes" resize="wh" type="listview" width="628" x="6" y="20" />',
        '<control height="372" multiline="yes" name="text" readonly="yes" resize="wh" type="edit" visible="no" width="628" x="6" y="20" />',
        '<control height="14" name="back" resize="y" title="Back" type="button" width="55" x="6" y="400" />',
        '<control height="14" name="copy" resize="y" title="Copy value" type="button" width="70" x="67" y="400" />',
        '<control height="14" name="expandAll" resize="y" title="Expand all" type="button" width="70" x="143" y="400" />',
        '<control height="14" name="collapseAll" resize="y" title="Collapse all" type="button" width="70" x="219" y="400" />',
        '<control close="1" height="14" name="close" resize="xy" title="Close" type="button" width="55" x="579" y="400" />',
        '</dialog>'
    ].join("");
}
