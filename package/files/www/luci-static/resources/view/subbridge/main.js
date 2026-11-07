'use strict';
'require view';
'require dom';
'require form';
'require poll';
'require rpc';
'require uci';
'require ui';

/*
 * SubBridge LuCI page.
 *
 * The page is deliberately a thin client: every privileged action goes
 * through the `subbridge` ubus object (rpcd/ucode backend), and the check
 * itself runs as a detached process. The browser only polls the progress
 * document, so the web interface stays responsive and the check survives a
 * page reload.
 */

var callInfo = rpc.declare({
	object: 'subbridge',
	method: 'info',
	expect: {}
});

var callStart = rpc.declare({
	object: 'subbridge',
	method: 'start',
	expect: {}
});

var callRestart = rpc.declare({
	object: 'subbridge',
	method: 'restart',
	expect: {}
});

var callPower = rpc.declare({
	object: 'subbridge',
	method: 'power',
	params: [ 'enabled' ],
	expect: {}
});

var callStatus = rpc.declare({
	object: 'subbridge',
	method: 'status',
	expect: {}
});

var callResult = rpc.declare({
	object: 'subbridge',
	method: 'result',
	expect: {}
});

function formatMs(value) {
	var ms = Number(value);

	if (!isFinite(ms) || ms <= 0)
		return '—';

	return Math.round(ms) + ' ms';
}

function formatSeconds(value) {
	var ms = Number(value);

	if (!isFinite(ms) || ms < 0)
		return '—';

	return (ms / 1000).toFixed(1) + ' ' + _('с');
}

function formatEndpoint(item) {
	var healthy = item.status === 'healthy';
	var icon = healthy ? '🟢' : '🔴';
	var name = (item.name != null && item.name !== '') ? item.name : _('без имени');
	var address = (item.address != null ? item.address : '') + ':' + (item.port != null ? item.port : 0);
	var detail = healthy ? formatMs(item.latency_ms) : (item.error != null && item.error !== '' ? item.error : _('недоступен'));

	return icon + ' ' + name + ' (' + address + ') — ' + detail;
}

/*
 * navigator.clipboard only exists in a secure context and LuCI is often served
 * over plain HTTP, so keep the textarea + execCommand fallback.
 */
function copyValue(value) {
	if (value == null || value === '')
		return Promise.reject(new Error(_('Нечего копировать')));

	if (navigator.clipboard && window.isSecureContext)
		return navigator.clipboard.writeText(value);

	var area = E('textarea', {
		'readonly': 'readonly',
		'style': 'position:fixed;top:-1000px;left:-1000px;width:1px;height:1px'
	}, [ value ]);

	document.body.appendChild(area);

	try {
		area.select();
		document.execCommand('copy');
	}
	catch (e) {
		/* Ignore; the caller flashes the button when the copy fails. */
	}
	finally {
		document.body.removeChild(area);
	}

	return Promise.resolve();
}

function eventButton(ev) {
	var el = ev && (ev.target || ev.currentTarget);

	if (el && el.nodeType === 3)
		el = el.parentNode;

	return (el && (el.tagName === 'BUTTON' || el.tagName === 'INPUT')) ? el : null;
}

/*
 * Show click feedback on the button itself: swap its label for a glyph for a
 * moment, then restore it. LuCI notifications stay on screen until dismissed,
 * so they are not used for routine actions such as Copy or Check.
 */
function flashButton(button, text, ok) {
	if (!button)
		return;

	if (button.__sbFlashTimer) {
		window.clearTimeout(button.__sbFlashTimer);
		button.__sbFlashTimer = null;
	}

	if (!button.__sbOriginal)
		button.__sbOriginal = { html: button.innerHTML, value: button.value };

	if (button.tagName === 'INPUT')
		button.value = text;
	else
		button.innerHTML = text;

	button.classList.remove('subbridge-flash', 'subbridge-flash-error');
	button.classList.add(ok === false ? 'subbridge-flash-error' : 'subbridge-flash');

	button.__sbFlashTimer = window.setTimeout(function() {
		if (button.tagName === 'INPUT')
			button.value = button.__sbOriginal.value;
		else
			button.innerHTML = button.__sbOriginal.html;

		button.classList.remove('subbridge-flash', 'subbridge-flash-error');
		button.__sbFlashTimer = null;
	}, 1200);
}

function hasSubscriptionChange(changes) {
	var ops = changes ? changes.subbridge : null;

	if (!ops || typeof ops.length !== 'number')
		return false;

	for (var i = 0; i < ops.length; i++) {
		var op = ops[i];

		/* rpcd reports changes as ["set"|"remove", section, option, value]. */
		if (op && op[1] === 'main' && op[2] === 'subscription')
			return true;
	}

	return false;
}

var PHASE_LABELS = {
	download: _('Загрузка подписки…'),
	parse: _('Разбор подписки…'),
	probe: _('Проверка возможностей движка…'),
	start: _('Запуск движка…'),
	check: _('Проверка endpoints…')
};

return view.extend({
	load: function() {
		/*
		 * Only the static information is loaded here. The previous check status
		 * and result are deliberately not fetched: reopening the page must show
		 * a clean start screen, with output appearing only after a new check.
		 */
		return L.resolveDefault(callInfo(), { version: '', engine: {}, settings: {} });
	},

	render: function(info) {
		this.info = info || {};
		this.status = { state: 'idle' };
		this.result = {};
		this.pollFn = null;
		this.packageOn = !(this.info.settings && this.info.settings.enabled === false);

		var map = new form.Map('subbridge', null, null);

		this.map = map;

		var section = map.section(form.NamedSection, 'main', 'subbridge');
		section.anonymous = true;

		var subscription = section.option(form.Value, 'subscription', _('Адрес подписки'));
		subscription.placeholder = 'https://...';
		subscription.rmempty = true;
		subscription.description = _('URL подписки');

		var checkButton = section.option(form.Button, '_check', _('Проверка'));
		checkButton.inputtitle = _('Проверить подписку');
		checkButton.inputstyle = 'apply';
		checkButton.onclick = L.bind(this.handleCheck, this);

		var settingsMap = new form.Map('subbridge', _('Настройки'), null);

		this.settingsMap = settingsMap;

		var settingsSection = settingsMap.section(form.NamedSection, 'main', 'subbridge');
		settingsSection.anonymous = true;

		var engineOption = settingsSection.option(form.Value, 'engine', _('Движок sing-box'));
		engineOption.placeholder = '/usr/bin/sing-box';
		engineOption.rmempty = true;
		engineOption.description = _('Укажи путь, либо оставь пустым для использования /usr/bin/sing-box');

		var testUrl = settingsSection.option(form.Value, 'test_url', _('URL для проверки'));
		testUrl.placeholder = 'http://cp.cloudflare.com/generate_204';
		testUrl.rmempty = true;
		testUrl.description = _('По умолчанию http://cp.cloudflare.com/generate_204');

		var timeout = settingsSection.option(form.Value, 'timeout_ms', _('Таймаут, мс'));
		timeout.placeholder = '3000';
		timeout.rmempty = true;
		timeout.datatype = 'range(500,60000)';

		var concurrency = settingsSection.option(form.Value, 'concurrency', _('Параллельных проверок'));
		concurrency.placeholder = '8';
		concurrency.rmempty = true;
		concurrency.datatype = 'range(1,32)';
		concurrency.description = _('Больше параллельных проверок — быстрее, но больше памяти.');

		var uaMap = new form.Map('subbridge', _('User Agent'), null);
		this.uaMap = uaMap;

		var uaSection = uaMap.section(form.NamedSection, 'main', 'subbridge');
		uaSection.anonymous = true;

		var uaMode = uaSection.option(form.ListValue, 'ua_mode', _('Режим заголовков'));
		uaMode.value('auto', _('Автоматически — Happ на Linux'));
		uaMode.value('custom', _('Свои значения'));
		uaMode.default = 'auto';
		uaMode.rmempty = false;
		uaMode.description = _('Автоматически отправляет Happ на Linux и при необходимости пробует другие встроенные клиенты. «Свои значения» отправляет только поля ниже.');

		var uaUserAgent = uaSection.option(form.Value, 'ua_user_agent', _('User-Agent'));
		uaUserAgent.placeholder = 'Happ/6.1.0/linux catalyst/2610091518671';
		uaUserAgent.default = 'Happ/6.1.0/linux catalyst/2610091518671';
		uaUserAgent.rmempty = true;
		uaUserAgent.depends('ua_mode', 'custom');
		uaUserAgent.description = _('Полная строка клиента, например скопированная с телефона.');

		var uaDeviceOs = uaSection.option(form.Value, 'ua_device_os', _('X-Device-OS'));
		uaDeviceOs.placeholder = 'Linux';
		uaDeviceOs.default = 'Linux';
		uaDeviceOs.rmempty = true;
		uaDeviceOs.depends('ua_mode', 'custom');
		uaDeviceOs.description = _('Операционная система устройства, например iOS, Android или Linux.');

		var uaVerOs = uaSection.option(form.Value, 'ua_ver_os', _('X-Ver-OS'));
		uaVerOs.placeholder = '6.6.0';
		uaVerOs.default = '6.6.0';
		uaVerOs.rmempty = true;
		uaVerOs.depends('ua_mode', 'custom');
		uaVerOs.description = _('Версия операционной системы устройства.');

		var uaAppVersion = uaSection.option(form.Value, 'ua_app_version', _('X-App-Version'));
		uaAppVersion.placeholder = '6.1.0';
		uaAppVersion.default = '6.1.0';
		uaAppVersion.rmempty = true;
		uaAppVersion.depends('ua_mode', 'custom');
		uaAppVersion.description = _('Версия приложения Happ, Incy или v2rayTun.');

		var uaDeviceModel = uaSection.option(form.Value, 'ua_device_model', _('X-Device-model'));
		uaDeviceModel.placeholder = 'Linux PC';
		uaDeviceModel.default = 'Linux PC';
		uaDeviceModel.rmempty = true;
		uaDeviceModel.depends('ua_mode', 'custom');
		uaDeviceModel.description = _('Модель устройства, например iPhone, Pixel 7 или Linux PC.');

		var uaDeviceLocale = uaSection.option(form.Value, 'ua_device_locale', _('X-Device-Locale'));
		uaDeviceLocale.placeholder = 'ru';
		uaDeviceLocale.default = 'ru';
		uaDeviceLocale.rmempty = true;
		uaDeviceLocale.depends('ua_mode', 'custom');
		uaDeviceLocale.description = _('Локаль устройства, обычно ru.');

		var uaHwid = uaSection.option(form.Value, 'ua_hwid', _('X-HWID'));
		uaHwid.placeholder = _('пусто — случайный');
		uaHwid.rmempty = true;
		uaHwid.depends('ua_mode', 'custom');
		uaHwid.description = _('Оставьте пустым, чтобы SubBridge создал случайный X-HWID и сохранил его. Вставьте X-HWID телефона, чтобы провайдер считал роутер тем же устройством.');

		/*
		 * In auto mode these fields are hidden by depends(). Without retain
		 * a save would delete them, so switching back to custom would lose
		 * the values the user copied from a phone.
		 */
		[ uaUserAgent, uaDeviceOs, uaVerOs, uaAppVersion, uaDeviceModel, uaDeviceLocale, uaHwid ].forEach(function(option) {
			option.retain = true;
		});

		this.actionsEl = E('div', { 'class': 'cbi-value', 'id': 'subbridge-actions' });
		this.progressEl = E('div', { 'class': 'cbi-section', 'id': 'subbridge-progress', 'style': 'display:none' });
		this.errorEl = E('div', { 'class': 'cbi-section', 'id': 'subbridge-error', 'style': 'display:none' });
		this.resultEl = E('div', { 'class': 'cbi-section', 'id': 'subbridge-result' });

		this.renderActions();

		var self = this;

		return map.render().then(function(node) {
			return settingsMap.render().then(function(settingsNode) {
				return uaMap.render().then(function(uaNode) {
				self.mapNode = node;
				self.updateCheckButton();
				var style = E('style', {}, [
					'#subbridge-result .subbridge-resolved { margin: 10px 0 18px; padding: 12px 14px; border-radius: 4px; background: rgba(128,128,128,.08); }',
					'#subbridge-result .subbridge-resolved-head { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px; }',
					'#subbridge-result .subbridge-resolved-label { font-weight: bold; }',
					'#subbridge-result .subbridge-resolved-url { display: block; margin: 8px 0; padding: 8px 10px; border-radius: 4px; background: rgba(0,0,0,.12); font-family: monospace; font-size: 90%; white-space: pre-wrap; word-break: break-all; }',
					'#subbridge-result .subbridge-resolved-note { font-size: 90%; opacity: .85; }',
					'#subbridge-result .subbridge-profiles-field { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }',
					'#subbridge-result .subbridge-endpoint-list { display: flex; flex-direction: column; gap: 6px; }',
					'#subbridge-result .subbridge-endpoint { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; padding: 10px 12px; border-radius: 4px; background: rgba(128,128,128,.08); }',
					'#subbridge-result .subbridge-endpoint.is-down { background: rgba(200,60,60,.08); }',
					'#subbridge-result .subbridge-endpoint.group-start { margin-top: 14px; border-top: 1px solid rgba(128,128,128,.35); padding-top: 16px; }',
					'#subbridge-result .subbridge-endpoint-text { flex: 0 1 auto; word-break: break-word; }',
					'#subbridge-result .subbridge-endpoint .cbi-button { flex: 0 0 auto; white-space: nowrap; }',
					'#subbridge-progress .cbi-progressbar { margin: 10px 0; }',
					'#subbridge-actions { margin: 6px 0 14px; }',
					'#subbridge-actions .subbridge-actions-row { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; }',
					'#subbridge-actions .subbridge-action { display: inline-flex; align-items: center; justify-content: flex-start; gap: 8px; min-width: 210px; white-space: nowrap; }',
					'#view #cbi-subbridge-main-_check .cbi-button { min-width: 210px; }',
					'#subbridge-actions .subbridge-action-icon { font-size: 1.1em; line-height: 1; }',
					'.subbridge-flash, .subbridge-flash:hover { background: #2e7d32 !important; border-color: #2e7d32 !important; color: #fff !important; }',
					'.subbridge-flash-error, .subbridge-flash-error:hover { background: #c62828 !important; border-color: #c62828 !important; color: #fff !important; }',
					'#cbi-subbridge .cbi-value-field input[type=text] { min-width: 34em; max-width: 100%; }',
					'.subbridge-profile-row { display: grid; grid-template-columns: minmax(0,1fr) auto; align-items: center; column-gap: 16px; min-height: 44px; padding: 8px 0; border-bottom: 1px solid rgba(128,128,128,.25); }',
					'.subbridge-profile-row:last-child { border-bottom: none; }',
					'.subbridge-profile-name { font-weight: bold; word-break: break-word; }',
					'.subbridge-profile-row .cbi-button { min-width: 110px; text-align: center; white-space: nowrap; }'
				]);

				var settingsPane = E('div', {
					'class': 'cbi-section',
					'data-tab': 'settings',
					'data-tab-title': _('Настройки')
				}, [
					settingsNode
				]);

				self.settingsPane = settingsPane;

				var uaPane = E('div', {
					'class': 'cbi-section',
					'data-tab': 'ua',
					'data-tab-title': _('User Agent')
				}, [
					uaNode
				]);

				self.uaPane = uaPane;

				var tabs = E('div', {}, [
					E('div', {
						'class': 'cbi-section',
						'data-tab': 'check',
						'data-tab-title': _('Проверка')
					}, [
						E('h2', { 'name': 'content' }, [ _('SubBridge') ]),
						E('div', { 'class': 'cbi-map-descr' }, [
							_('Версия %s').format(self.info.version || '—')
						]),
						self.actionsEl,
						node,
						self.progressEl,
						self.errorEl,
						self.resultEl
					]),
					settingsPane,
					uaPane
				]);

				var root = E([], [ style, tabs ]);

				/*
				 * initTabGroup needs the pane container to have a parent so it
				 * can insert the tab menu before it; keep the container inside
				 * a fragment until LuCI mounts the view.
				 */
				ui.tabs.initTabGroup(tabs.childNodes);

				/*
				 * The default Save / Save & Apply / Reset bar is appended to
				 * #view after render. Keep it out of the Check tab and move it
				 * to whichever settings tab is active.
				 */
				window.setTimeout(function() {
					var footer = document.querySelector('#view > .cbi-page-actions');

					if (!footer)
						return;

					/* Restore the tab selection from LuCI's session before
					 * deciding where the Save bar belongs. */
					var activePane = uaPane.getAttribute('data-tab-active') === 'true'
						? uaPane
						: settingsPane;

					activePane.appendChild(footer);

					var menu = tabs.previousElementSibling;

					if (!menu || !menu.querySelectorAll)
						return;

					var links = menu.querySelectorAll('li[data-tab] > a');

					for (var i = 0; i < links.length; i++) {
						links[i].addEventListener('click', function(ev) {
							var item = ev.currentTarget.parentNode;
							var id = item ? item.getAttribute('data-tab') : '';

							if (id === 'settings')
								settingsPane.appendChild(footer);
							else if (id === 'ua')
								uaPane.appendChild(footer);
						});
					}
				}, 0);

				return root;
				});
			});
		});
	},

	renderActions: function() {
		var self = this;
		var packageOn = !!this.packageOn;

		var actions = [
			E('button', {
				'class': 'cbi-button cbi-button-apply subbridge-action subbridge-action-restart',
				'click': function(ev) { return self.handleRestart(ev); }
			}, [
				E('span', { 'class': 'subbridge-action-icon' }, [ '↻' ]),
				E('span', {}, [ _('Перезапустить SubBridge') ])
			]),
			packageOn
				? E('button', {
					'class': 'cbi-button cbi-button-negative subbridge-action subbridge-action-power',
					'click': function(ev) { return self.handlePower(ev); }
				}, [
					E('span', { 'class': 'subbridge-action-icon' }, [ '■' ]),
					E('span', {}, [ _('Отключить SubBridge') ])
				])
				: E('button', {
					'class': 'cbi-button cbi-button-apply subbridge-action subbridge-action-power',
					'click': function(ev) { return self.handlePower(ev); }
				}, [
					E('span', { 'class': 'subbridge-action-icon' }, [ '▶' ]),
					E('span', {}, [ _('Запустить SubBridge') ])
				])
		];

		dom.content(this.actionsEl, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Доступные действия:') ]),
			E('div', { 'class': 'cbi-value-field' }, [
				E('div', { 'class': 'subbridge-actions-row' }, actions)
			])
		]);

		this.updateCheckButton();
	},

	updateCheckButton: function() {
		var node = this.mapNode;
		var button = node ? node.querySelector('button.cbi-button-apply') : null;

		/*
		 * The width is set in CSS against the option row (#cbi-subbridge-main-_check)
		 * because LuCI re-renders the map after a save and would drop any class
		 * or inline style added here.
		 */
		if (button)
			button.disabled = !this.packageOn;
	},

	commitSubscription: function() {
		/*
		 * The check reads /etc/config directly, so a new subscription URL must
		 * be committed before the process starts. Only this map is saved:
		 * edits on the Settings and User Agent tabs stay pending until the
		 * user presses Save & Apply.
		 */
		return this.map.save(null, true).then(function() {
			return uci.changes();
		}).then(function(changes) {
			/* Apply only when this action staged a new subscription URL.
			   Changes previously staged from the settings tabs (an explicit
			   "Save" without "Apply") must not be applied by a check. */
			if (!hasSubscriptionChange(changes))
				return null;

			return uci.apply().then(function() {
				/* uci.apply() bypasses the change tracker used by the badge. */
				if (ui.changes && typeof ui.changes.init === 'function')
					return ui.changes.init();
			});
		});
	},

	handleCheck: function(ev) {
		var self = this;

		if (ev && typeof ev.preventDefault === 'function')
			ev.preventDefault();

		if (this.pollFn)
			return false;

		this.hideError();
		this.clearResult();

		return this.commitSubscription().then(function() {
			return callStart();
		}).then(function(reply) {
			if (reply && reply.error)
				throw new Error(reply.error);

			self.renderProgress({ state: 'starting', phase: '', total: 0, done: 0 });
			self.startPolling();
		}).catch(function(e) {
			self.showError(e && e.message ? e.message : String(e));
		});
	},

	handleRestart: function(ev) {
		var self = this;

		if (ev && typeof ev.preventDefault === 'function')
			ev.preventDefault();

		/*
		 * Restart the package runtime, not the subscription check: stop the
		 * running job, clear transient state and return to idle with the
		 * package switched on.
		 */
		this.stopPolling();
		this.hideError();
		this.hideProgress();
		this.clearResult();

		return callRestart().then(function(reply) {
			if (reply && reply.error)
				throw new Error(reply.error);

			self.packageOn = true;
			self.info.settings = self.info.settings || {};
			self.info.settings.enabled = true;
			self.renderActions();
		}).catch(function(e) {
			self.showError(e && e.message ? e.message : String(e));
		});
	},

	handlePower: function(ev) {
		var self = this;
		var on = !this.packageOn;

		if (ev && typeof ev.preventDefault === 'function')
			ev.preventDefault();

		if (!on) {
			this.stopPolling();
			this.hideProgress();
			this.hideError();
			this.clearResult();
		}

		return callPower(on ? '1' : '0').then(function(reply) {
			if (reply && reply.error)
				throw new Error(reply.error);

			self.packageOn = !!(reply && reply.enabled);
			self.info.settings = self.info.settings || {};
			self.info.settings.enabled = self.packageOn;
			self.renderActions();
		}).catch(function(e) {
			self.showError(e && e.message ? e.message : String(e));
		});
	},

	startPolling: function() {
		var self = this;

		if (this.pollFn)
			return;

		this.pollFn = function() {
			return callStatus().then(function(st) {
				self.status = st || { state: 'idle' };

				if (self.status.state === 'done') {
					self.stopPolling();
					return callResult().then(function(result) {
						self.result = result || {};
						self.hideProgress();
						self.renderResult(self.result);
					});
				}

				if (self.status.state === 'error') {
					self.stopPolling();
					self.hideProgress();
					self.showError(self.status.message || _('Неизвестная ошибка'));
					return;
				}

				self.renderProgress(self.status);
			}).catch(function() {
				/* rpcd can be briefly busy; the next tick retries. */
			});
		};

		poll.add(this.pollFn, 1);
	},

	stopPolling: function() {
		if (this.pollFn) {
			poll.remove(this.pollFn);
			this.pollFn = null;
		}
	},

	renderProgress: function(status) {
		var total = Number(status.total) || 0;
		var done = Number(status.done) || 0;
		var percent = total > 0 ? Math.round(done * 100 / total) : 0;
		var label = total > 0
			? _('Проверка endpoints: %d / %d').format(done, total)
			: (PHASE_LABELS[status.phase] || _('Проверка выполняется…'));

		dom.content(this.progressEl, [
			E('h3', {}, [ _('Проверка выполняется') ]),
			E('div', { 'class': 'cbi-progressbar', 'title': percent + '%' }, [
				E('div', { 'style': 'width:%d%%'.format(percent) })
			]),
			E('div', { 'class': 'cbi-section-descr' }, [ label ])
		]);

		this.progressEl.style.display = '';
	},

	hideProgress: function() {
		this.progressEl.style.display = 'none';
	},

	clearResult: function() {
		this.result = {};
		dom.content(this.resultEl, []);
	},

	showError: function(message) {
		dom.content(this.errorEl, [
			E('h3', {}, [ _('Ошибка проверки') ]),
			E('div', { 'class': 'cbi-section-descr' }, [ '✗ ' + message ])
		]);

		this.errorEl.style.display = '';
		this.hideProgress();
	},

	hideError: function() {
		this.errorEl.style.display = 'none';
	},

	renderResult: function(result) {
		if (!result || result.endpoints == null) {
			this.clearResult();
			return;
		}

		var self = this;
		var nodes = [ E('h3', {}, [ _('Результат проверки') ]) ];

		if (result.subscription_url) {
			nodes.push(E('div', { 'class': 'subbridge-resolved' }, [
				E('div', { 'class': 'subbridge-resolved-head' }, [
					E('span', { 'class': 'subbridge-resolved-label' }, [ _('Рабочая ссылка подписки') ]),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function(ev) { return self.handleCopy(result.subscription_url, ev); }
					}, [ _('Копировать') ])
				]),
				E('code', { 'class': 'subbridge-resolved-url' }, [ result.subscription_url ]),
				E('div', { 'class': 'subbridge-resolved-note' }, [
					_('Заголовок подписки: '),
					E('strong', {}, [ result.header_preset || '—' ]),
					_('. Ссылка работает с этими заголовками.')
				]),
				(result.header_lines && result.header_lines.length > 0)
					? E('div', { 'style': 'margin-top:8px' }, [
						E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'click': function(ev) {
								return self.handleCopy(result.header_lines.join('\n'), ev);
							}
						}, [ _('Копировать заголовки') ])
					])
					: ''
			]));
		}

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Статус') ]),
			E('div', { 'class': 'cbi-value-field' }, [
				'✓ ' + _('Работает: %d из %d').format(Number(result.online) || 0, Number(result.endpoints) || 0)
			])
		]));

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Профили') ]),
			E('div', { 'class': 'cbi-value-field subbridge-profiles-field' }, [
				E('span', {}, [ String(Number(result.profiles) || 0) ]),
				(result.profile_items && result.profile_items.length > 0)
					? E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() { return self.showProfiles(); }
					}, [ _('Смотреть') ])
					: ''
			])
		]));

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Endpoints') ]),
			E('div', { 'class': 'cbi-value-field' }, [ String(Number(result.endpoints) || 0) ])
		]));

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Доступно') ]),
			E('div', { 'class': 'cbi-value-field' }, [ String(Number(result.online) || 0) ])
		]));

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Недоступно') ]),
			E('div', { 'class': 'cbi-value-field' }, [ String(Number(result.offline) || 0) ])
		]));

		nodes.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('Время проверки') ]),
			E('div', { 'class': 'cbi-value-field' }, [ formatSeconds(result.elapsed_ms) ])
		]));

		if (result.best) {
			nodes.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Лучший endpoint') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					'🟢 ' + (result.best.name || _('без имени')) +
					' (' + (result.best.address || '') + ':' + (Number(result.best.port) || 0) + ') — ' +
					formatMs(result.best.latency_ms)
				])
			]));
		}

		var items = (result.results || []).slice();

		if (items.length > 0) {
			var latencySum = 0;
			var latencyCount = 0;

			for (var i = 0; i < items.length; i++) {
				if (items[i].status === 'healthy' && Number(items[i].latency_ms) > 0) {
					latencySum += Number(items[i].latency_ms);
					latencyCount++;
				}
			}

			nodes.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Средняя задержка') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					latencyCount > 0 ? formatMs(latencySum / latencyCount) : '—'
				])
			]));

			items.sort(function(a, b) {
				var au = (a.status === 'healthy') ? 0 : 1;
				var bu = (b.status === 'healthy') ? 0 : 1;

				if (au !== bu)
					return au - bu;

				if (au === 0)
					return (Number(a.latency_ms) || 0) - (Number(b.latency_ms) || 0);

				return 0;
			});

			var rows = [];
			var previousHealthy = true;

			for (var j = 0; j < items.length; j++) {
				var item = items[j];
				var healthy = item.status === 'healthy';
				var css = 'subbridge-endpoint ' + (healthy ? 'is-up' : 'is-down');

				if (!healthy && previousHealthy)
					css += ' group-start';

				previousHealthy = healthy;

				rows.push(E('div', { 'class': css }, [
					E('span', { 'class': 'subbridge-endpoint-text' }, [ formatEndpoint(item) ]),
					(item.url != null && item.url !== '')
						? E('button', {
							'class': 'cbi-button cbi-button-neutral subbridge-copy',
							'click': function(url) {
								return function(ev) { return self.handleCopy(url, ev); };
							}(item.url)
						}, [ _('Копировать') ])
						: ''
				]));
			}

			nodes.push(E('div', { 'class': 'cbi-section', 'id': 'subbridge-endpoints' }, [
				E('h3', {}, [ items.length === 1 ? _('Endpoint') : _('Endpoints') ]),
				E('div', { 'class': 'subbridge-endpoint-list' }, rows)
			]));
		}

		dom.content(this.resultEl, nodes);
	},

	showProfiles: function() {
		var self = this;
		var profiles = (this.result && this.result.profile_items) || [];
		var rows = [];

		for (var i = 0; i < profiles.length; i++) {
			rows.push(E('div', { 'class': 'subbridge-profile-row' }, [
				E('span', { 'class': 'subbridge-profile-name' }, [
					profiles[i].name || _('Профиль %d').format(i + 1)
				]),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function(profile) {
						return function(ev) { return self.handleCopy(profile.payload, ev); };
					}(profiles[i])
				}, [ _('Копировать') ])
			]));
		}

		ui.showModal(_('Профили подписки'), [
			E('div', { 'style': 'max-height:60vh;overflow-y:auto;padding:0 20px' }, rows),
			E('div', { 'class': 'right', 'style': 'padding-top:12px' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Закрыть') ])
			])
		]);
	},

	handleCopy: function(value, ev) {
		var button = eventButton(ev);

		return copyValue(value).then(function() {
			flashButton(button, '✓');
		}).catch(function() {
			flashButton(button, '✗', false);
		});
	}
});
