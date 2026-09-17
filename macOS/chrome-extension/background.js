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
    const body = `url=${download.finalUrl || download.url}\nfile=${download.filename || ""}\n`;
    const response = await fetch("http://127.0.0.1:9614/download", {
      method: "POST",
      body
    });
    if (!response.ok) return;
    await chrome.downloads.cancel(download.id);
    await chrome.downloads.erase({ id: download.id });
  } catch (error) {
    console.error("XDM New handoff failed; Chrome continues the original download.", error);
  }
});
