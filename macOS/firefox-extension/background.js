const HOST_NAME = "org.xdm.test";
let monitoringEnabled = false;

async function updateAction() {
  await browser.browserAction.setTitle({
    title: monitoringEnabled ? "XDM monitoring is on" : "Enable XDM download monitoring"
  });
  await browser.browserAction.setBadgeText({ text: monitoringEnabled ? "ON" : "" });
  await browser.browserAction.setBadgeBackgroundColor({ color: "#008bb8" });
}

browser.runtime.onStartup.addListener(async () => {
  ({ monitoringEnabled = false } = await browser.storage.local.get("monitoringEnabled"));
  await updateAction();
});

browser.browserAction.onClicked.addListener(async () => {
  monitoringEnabled = !monitoringEnabled;
  await browser.storage.local.set({ monitoringEnabled });
  await updateAction();
});

browser.downloads.onCreated.addListener(async (download) => {
  if (!monitoringEnabled || !download.url || !/^https?:/i.test(download.url)) return;

  try {
    const response = await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "download",
      url: download.url,
      filename: download.filename || null
    });
    if (!response.accepted) return;

    // Firefox may have already started the request; stop its duplicate copy once XDM accepted the handoff.
    await browser.downloads.cancel(download.id);
    await browser.downloads.erase({ id: download.id });
  } catch (error) {
    console.error("XDM handoff failed; Firefox continues the original download.", error);
  }
});
