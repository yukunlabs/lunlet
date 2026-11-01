// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.01, AC-28.03; US-27, AC-27.04; US-30, AC-30.01, AC-30.02, AC-30.03.
"use strict";

(() => {
  // Only owner-configured destinations become links; everything else stays hidden rather than pointing at a placeholder.
  const config = window.LUNLET_SITE_CONFIG || {};
  for (const link of document.querySelectorAll("[data-link]")) {
    const destination = config[link.dataset.link];
    if (destination) {
      link.href = destination;
      link.hidden = false;
      link.rel = "noopener noreferrer";
    }
  }
  if (config.releaseURL) {
    document.querySelector("#release-status").textContent =
      "The download is an unsigned preview: on first open, allow it in System Settings › Privacy & Security (Open Anyway), and after each update authorize the saved bot connection once. Requirements, release notes and checksums are on GitHub. No new mobile conversations, SSH, remote-host discovery or general computer control.";
  }

  // One messenger at a time: the tabs swap the three phones and their note, with roving focus and arrow keys.
  const tablist = document.querySelector('[role="tablist"]');
  if (tablist) {
    const tabs = [...tablist.querySelectorAll('[role="tab"]')];
    const panels = tabs.map(tab => document.getElementById(tab.getAttribute("aria-controls")));
    const select = (index, focus) => {
      tabs.forEach((tab, i) => {
        const on = i === index;
        tab.setAttribute("aria-selected", String(on));
        tab.tabIndex = on ? 0 : -1;
        if (on && focus) tab.focus();
      });
      panels.forEach((panel, i) => {
        const on = i === index;
        panel.hidden = false;
        panel.classList.toggle("is-hidden", !on);
        panel.inert = !on;
        panel.setAttribute("aria-hidden", String(!on));
      });
    };
    tabs.forEach((tab, i) => {
      tab.addEventListener("click", () => select(i, false));
      tab.addEventListener("keydown", event => {
        const moves = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 };
        if (!(event.key in moves)) return;
        event.preventDefault();
        select((moves[event.key] + tabs.length) % tabs.length, true);
      });
    });
    select(0, false);
  }

  // Sections rise gently into view as you scroll; with reduced motion, or without observers, everything is simply shown.
  const targets = document.querySelectorAll(".reveal");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced || !("IntersectionObserver" in window)) {
    for (const target of targets) target.classList.add("in");
    return;
  }
  document.documentElement.classList.add("motion");
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.1 });
  for (const target of targets) observer.observe(target);
})();
