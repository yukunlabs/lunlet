// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-28, AC-28.01, AC-28.02, AC-28.03; US-30, AC-30.01, AC-30.02, AC-30.03.
"use strict";

(() => {
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
      "Find the current macOS download, requirements, release notes and checksums on GitHub.";
  }

  const artwork = window.LUNLET_ARTWORK;
  const ns = "http://www.w3.org/2000/svg";
  function svgElement(tag, attributes) {
    const element = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
    return element;
  }
  if (artwork) {
    for (const [side, key] of [["left", "leftInk"], ["right", "rightInk"]]) {
      const svg = document.querySelector(`.${side}-word`);
      const defs = svgElement("defs", {});
      const gradient = svgElement("linearGradient", { id: `pearl-${side}`, x2: ".65", y2: "1" });
      for (const [offset, color] of [["0%", "#f3f4ff"], ["40%", "#d8e4ff"], ["100%", "#917bc5"]]) {
        gradient.append(svgElement("stop", { offset, "stop-color": color }));
      }
      defs.append(gradient);
      const path = svgElement("path", { d: artwork[key] });
      path.style.stroke = `url(#pearl-${side})`;
      svg.append(defs, path);
    }
    const vine = document.querySelector(".vine");
    vine.append(svgElement("path", { d: artwork.body, class: "track" }));
    vine.append(svgElement("path", { d: artwork.body, class: "fill", pathLength: "100", "stroke-dasharray": "100" }));
  }
  const lamps = document.querySelector(".lamps");
  for (let index = 0; index < 5; index += 1) {
    const lamp = document.createElement("span");
    lamp.className = "lamp";
    lamps.append(lamp);
  }

  const range = document.querySelector("#allowance-range");
  range.disabled = !artwork;
  function allowanceChanged() {
    if (!artwork) return;
    const remaining = Number(range.value);
    document.querySelector("#remaining-label").textContent = `${remaining}% left`;
    document.querySelector("#control-value").textContent = `${remaining}%`;
    const stops = artwork.palette;
    const amount = Math.min(20, remaining);
    const upper = stops.findIndex(stop => stop[0] >= amount);
    const high = stops[upper], low = stops[Math.max(0, upper - 1)];
    const fraction = high[0] === low[0] ? 1 : (amount - low[0]) / (high[0] - low[0]);
    const blend = fraction * fraction * (3 - 2 * fraction);
    const colors = high[1].map((highColor, index) => {
      const lowColor = low[1][index];
      const channels = [16, 8, 0].map(shift => Math.round(((lowColor >> shift) & 255) + (((highColor >> shift) & 255) - ((lowColor >> shift) & 255)) * blend));
      return "#" + channels.map(channel => channel.toString(16).padStart(2, "0")).join("");
    });
    const color = colors[1];
    document.documentElement.style.setProperty("--quota-from", colors[0]);
    document.documentElement.style.setProperty("--quota-to", colors[2]);
    document.documentElement.style.setProperty("--quota-color", color);
    document.querySelector(".quota-fill").style.width = `${remaining}%`;
    document.querySelector(".quota").setAttribute("aria-valuenow", String(remaining));
    const vineFill = document.querySelector(".vine .fill");
    if (vineFill) vineFill.setAttribute("stroke-dashoffset", String(100 - remaining));
    for (const [index, lamp] of [...lamps.children].entries()) {
      const brightness = Math.max(0, Math.min(1, remaining / 20 - index));
      lamp.style.opacity = String(.1 + .9 * brightness);
      lamp.style.boxShadow = `0 0 ${brightness * 7}px #ff7e5966`;
    }
  }
  range.addEventListener("input", allowanceChanged);
  allowanceChanged();
  for (const button of document.querySelectorAll("[data-skin]")) {
    button.addEventListener("click", () => {
      for (const sibling of document.querySelectorAll("[data-skin]")) {
        const selected = sibling === button;
        sibling.classList.toggle("selected", selected);
        sibling.setAttribute("aria-pressed", String(selected));
      }
      const festive = button.dataset.skin === "lantern";
      document.querySelector(".vine").toggleAttribute("hidden", festive);
      lamps.hidden = !festive;
    });
  }

  // Both metrics refer to the same five synthetic local days.
  const days = [
    { label: "Mon", tokens: 28000, cost: .12 },
    { label: "Tue", tokens: 92000, cost: .42 },
    { label: "Wed", tokens: 61000, cost: .26 },
    { label: "Thu", tokens: 19000, cost: .08 },
    { label: "Fri", tokens: 42000, cost: .18 }
  ];
  function renderChart(metric) {
    const chart = document.querySelector(".chart");
    const maximum = Math.max(...days.map(day => metric === "cost" ? day.cost : day.tokens));
    chart.replaceChildren();
    chart.setAttribute("aria-label", `Illustrative five-day ${metric === "cost" ? "estimated API cost" : "token"} usage`);
    for (const day of days) {
      const value = metric === "cost" ? day.cost : day.tokens;
      const label = metric === "cost" ? `≈$${value.toFixed(2)}` : `${day.tokens / 1000}K`;
      const column = document.createElement("div");
      column.className = "bar-column";
      column.setAttribute("aria-label", `${day.label}: ${day.tokens} tokens, estimated API cost $${day.cost.toFixed(2)}`);
      const caption = document.createElement("span");
      caption.textContent = label;
      const bar = document.createElement("div");
      bar.className = "bar";
      bar.style.height = `${Math.max(2, 42 * value / maximum)}px`;
      const date = document.createElement("small");
      date.textContent = day.label;
      column.append(caption, bar, date);
      chart.append(column);
    }
  }
  for (const button of document.querySelectorAll("[data-metric]")) {
    button.addEventListener("click", () => {
      for (const sibling of document.querySelectorAll("[data-metric]")) {
        const selected = sibling === button;
        sibling.classList.toggle("selected", selected);
        sibling.setAttribute("aria-pressed", String(selected));
      }
      renderChart(button.dataset.metric);
    });
  }
  renderChart("token");

  const cueButton = document.querySelector(".run-demo");
  let cueTimer;
  function finishCue() {
    document.querySelector(".screen").classList.remove("cue");
    document.querySelector(".demo-state").textContent = "Quietly in view";
    document.querySelector(".session-state").textContent = "Turn in progress · a1b2c3d4";
    cueButton.disabled = false;
  }
  cueButton.addEventListener("click", () => {
    clearTimeout(cueTimer);
    cueButton.disabled = true;
    document.querySelector(".screen").classList.add("cue");
    document.querySelector(".demo-state").textContent = "Task finished";
    document.querySelector(".session-state").textContent = "Turn finished · a1b2c3d4";
    document.querySelector(".screen").scrollIntoView({ block: "center", behavior: "auto" });
    cueTimer = setTimeout(finishCue, 3500);
  });
  window.addEventListener("pagehide", () => { clearTimeout(cueTimer); finishCue(); });
})();
