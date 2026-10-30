// Source: sweopsbench.pdf, Table 3. All performance values are percentages.
const results = [
  { agent: 'Claude Code', model: 'Claude-Sonnet-5', healthy: 94.5, faulty: 90.9, paired: 85.5, file: 65.5, func: 38.2, joint: 38.2, rec: 52.7 },
  { agent: 'Claude Code', model: 'DeepSeek-V4.1-Flash', healthy: 83.6, faulty: 87.3, paired: 72.7, file: 65.5, func: 30.9, joint: 30.9, rec: 47.3 },
  { agent: 'Codex', model: 'DeepSeek-V4.1-Flash', healthy: 43.6, faulty: 85.5, paired: 38.2, file: 63.6, func: 50.9, joint: 50.9, rec: 45.5 },
  { agent: 'Codex', model: 'GLM-5.3-Flash', healthy: 72.7, faulty: 74.5, paired: 60.0, file: 54.5, func: 43.6, joint: 43.6, rec: 34.5 },
  { agent: 'Codex', model: 'GPT-5.6 Luna', healthy: 85.5, faulty: 76.4, paired: 72.7, file: 50.9, func: 36.4, joint: 36.4, rec: 30.9 },
  { agent: 'Claude Code', model: 'GLM-5.3-Flash', healthy: 67.3, faulty: 72.7, paired: 45.5, file: 25.5, func: 5.5, joint: 5.5, rec: 14.5 }
];
const metrics = ['rec', 'healthy', 'faulty', 'paired', 'file', 'func', 'joint'];
const maximum = Object.fromEntries(metrics.map(key => [key, Math.max(...results.map(row => row[key]))]));
const state = { sort: 'rec', direction: 'descending', agent: 'all' };
function selectedResults() {
  return results.filter(row => state.agent === 'all' || row.agent === state.agent)
    .sort((a, b) => (state.direction === 'descending' ? b[state.sort] - a[state.sort] : a[state.sort] - b[state.sort]) || b.rec - a.rec);
}
function renderResults() {
  const rows = selectedResults();
  document.querySelector('#results-body').innerHTML = rows.map((row, index) => {
    const scores = metrics.map(key => {
      const classes = [row[key] === maximum[key] ? 'best' : '', ['healthy', 'file'].includes(key) ? 'group-boundary' : '', key === 'rec' ? 'recovery-cell' : ''].filter(Boolean).join(' ');
      const value = row[key].toFixed(1);
      return `<td class="${classes}">${key === 'rec' ? `<span class="recovery-score"><span class="score-track" aria-hidden="true"><i style="width:${value}%"></i></span><span>${value}</span></span>` : value}</td>`;
    }).join('');
    return `<tr><td class="rank-cell">${String(index + 1).padStart(2, '0')}</td><td class="model-cell">${row.model}<span class="mobile-agent">${row.agent}</span></td><td class="agent-cell"><span class="agent-pill">${row.agent}</span></td>${scores}</tr>`;
  }).join('');
  document.querySelector('#result-count').textContent = `${rows.length} configurations`;
  document.querySelectorAll('th[data-key]').forEach(header => {
    const active = header.dataset.key === state.sort;
    if (active) header.setAttribute('aria-sort', state.direction);
    else header.removeAttribute('aria-sort');
    header.querySelector('.sort-icon').textContent = active ? (state.direction === 'descending' ? '↓' : '↑') : '↕';
  });
}
document.querySelectorAll('[data-sort]').forEach(button => button.addEventListener('click', () => {
  const key = button.dataset.sort;
  state.direction = state.sort === key && state.direction === 'descending' ? 'ascending' : 'descending';
  state.sort = key;
  renderResults();
}));
document.querySelector('#agent-filter').addEventListener('change', event => { state.agent = event.target.value; renderResults(); });
document.querySelector('#export-results').addEventListener('click', () => {
  const keys = ['model', 'agent', ...metrics];
  const headings = ['Model', 'Agent', 'Recovery (%)', 'Healthy detection (%)', 'Faulty detection (%)', 'Paired detection (%)', 'File RCA (%)', 'Function RCA (%)', 'Joint RCA (%)'];
  const csv = [headings.join(','), ...selectedResults().map(row => keys.map(key => typeof row[key] === 'number' ? row[key].toFixed(1) : `"${row[key].replaceAll('"', '""')}"`).join(','))].join('\r\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  const link = document.createElement('a'); link.href = url; link.download = 'sweops-bench-results.csv'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
// Source: Figure 3. Both charts use a common 0–20 task scale.
function renderChart(selector, values, className = '') {
  const element = document.querySelector(selector);
  element.classList.add(...(className ? [className] : []));
  element.innerHTML = values.map(([label, count]) => `<div class="chart-row"><span>${label}</span><div class="chart-track" aria-hidden="true"><i style="width:${count / 20 * 100}%"></i></div><span class="chart-number">${count}</span></div>`).join('');
}
renderChart('#fault-chart', [['Construction', 15], ['Defensive handling', 13], ['Input validation', 10], ['Control logic', 9], ['Lifecycle / ownership', 5], ['Admission policy', 3]]);
renderChart('#symptom-chart', [['Workload degraded', 19], ['Operator crash', 17], ['Resource rejected', 9], ['Operator-reported', 5], ['Storage blocked', 5]], 'symptoms');
const projects = [['Redis', 9], ['VictoriaMetrics', 9], ['MongoDB · MongoOp', 5], ['MongoDB · PCN/MongoOp', 5], ['PostgreSQL', 4], ['Cassandra', 3], ['Knative', 3], ['Percona XtraDB', 3], ['ZooKeeper', 3], ['Grafana', 2], ['Apache Spark', 2], ['OpenTelemetry', 2], ['Ceph', 2], ['Fluent Bit', 1], ['Prometheus', 1], ['RabbitMQ', 1]];
document.querySelector('#project-list').innerHTML = projects.map(([name, count]) => `<div class="project-item"><span>${name}</span><b>${count}</b></div>`).join('');
const navigation = [...document.querySelectorAll('.site-header nav a')];
const observer = new IntersectionObserver(entries => {
  const visible = entries.filter(entry => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
  if (visible.length) navigation.forEach(link => link.classList.toggle('nav-active', link.hash === '#' + visible[0].target.id));
}, { rootMargin: '-80px 0px -55% 0px', threshold: 0 });
navigation.forEach(link => observer.observe(document.querySelector(link.hash)));
renderResults();
