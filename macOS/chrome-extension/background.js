let monitoringEnabled = false;

async function updateAction() {
  await chrome.action.setTitle({ title: monitoringEnabled ? "XDM New monitoring is on" : "Enable XDM New download monitoring" });
  await chrome.action.setBadgeText({ text: monitoringEnabled ? "ON" : "" });
  await chrome.action.setBadgeBackgroundColor({ color: "#008bb8" });
}

chrome.runtime.onStartup.addListener(async () => {
  ({ monitoringEnabled = false } = await chrome.storage.local.get("monitoringEnabled"));
  await updateAction();
});

chrome.runtime.onInstalled.addListener(async () => {
  ({ monitoringEnabled = false } = await chrome.storage.local.get("monitoringEnabled"));
  await updateAction();
});

chrome.action.onClicked.addListener(async () => {
  monitoringEnabled = !monitoringEnabled;
  await chrome.storage.local.set({ monitoringEnabled });
  await updateAction();
});

chrome.downloads.onCreated.addListener(async (download) => {
  if (!monitoringEnabled || !download.url || !/^https?:/i.test(download.url)) return;
  try {
    // A URL-scheme handoff avoids the contested legacy XDM port (9614).
    // macOS routes this directly to the installed XDM New.app.
    const handoff = new URL("xdmtest://download");
    handoff.searchParams.set("url", download.finalUrl || download.url);
    if (download.filename) handoff.searchParams.set("filename", download.filename);
    await chrome.tabs.create({ url: handoff.toString(), active: false });
    await chrome.downloads.cancel(download.id);
    await chrome.downloads.erase({ id: download.id });
  } catch (error) {
    console.error("XDM New handoff failed; Chrome continues the original download.", error);
  }
});
