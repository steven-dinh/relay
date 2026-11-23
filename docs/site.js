const contents = document.querySelector(".contents");
const narrow = window.matchMedia("(max-width: 54rem)");
function setContentsOpen() {
  contents.open = !narrow.matches;
}
setContentsOpen();
narrow.addEventListener("change", setContentsOpen);

// Keep bookmarks from earlier versions of the docs working.
function followOldBookmark() {
  const oldSection = location.hash.slice(1).replace(/-title$/, "");
  const quickstart = document.getElementById("quick-start");
  if (oldSection === "versions" || oldSection === "changelog") {
    if (quickstart || document.getElementById("events")) location.replace("./changelog.html");
    return;
  }
  if (!quickstart) return;
  const guideSections = ["types", "events", "api", "cleanup", "guardrails", "development-build"];
  if (guideSections.includes(oldSection)) {
    location.replace("./guide.html#" + oldSection);
  } else if (oldSection === "benchmarks") {
    location.replace("./benchmarks.html");
  } else if (oldSection === "general" || oldSection === "setup") {
    location.replace("#published-install");
  } else if (["top", "home", "overview"].includes(oldSection)) {
    location.replace("#quick-start");
  }
}
followOldBookmark();
window.addEventListener("hashchange", followOldBookmark);

if (navigator.clipboard && navigator.clipboard.writeText) {
  for (const code of document.querySelectorAll("code[data-file]")) {
    const tools = document.createElement("div");
    tools.className = "code-tools";
    const status = document.createElement("span");
    status.setAttribute("role", "status");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Copy script";
    button.setAttribute("aria-label", "Copy " + code.dataset.file);
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.textContent);
        status.textContent = "Copied";
      } catch {
        status.textContent = "Select the code and copy it manually.";
      }
    });
    tools.append(status, button);
    code.closest(".code-frame").before(tools);
  }
}
