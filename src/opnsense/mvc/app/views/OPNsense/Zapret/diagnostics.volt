{#
    Copyright (C) 2026 Umur Gorur
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
#}

<script>
    // Try to parse a string as JSON, return null on failure.
    function tryJSON(s) {
        try { return JSON.parse(s); } catch (e) { return null; }
    }

    $(document).ready(function() {
        // ---- Test Domain Connectivity ----
        $("#testDomainBtn").click(function() {
            var domain = $("#testDomainInput").val().trim();
            if (!domain) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("Warning") }}',
                    message: '{{ lang._("Please enter a domain name.") }}'
                });
                return;
            }
            $("#testDomainBtn_progress").addClass("fa fa-spinner fa-pulse");
            $("#testDomainResult").text("Testing...");
            ajaxCall('/api/zapret/diagnostics/testdomain', {'domain': domain}, function(data, status) {
                $("#testDomainBtn_progress").removeClass("fa fa-spinner fa-pulse");
                if (data.status === 'ok') {
                    $("#testDomainResult").text(data.result);
                } else {
                    $("#testDomainResult").text("Error: " + (data.message || "Unknown error"));
                }
            });
        });

        // ---- Blockcheck (Strategy Finder) ----
        $("#blockcheckBtn").click(function() {
            var domain = $("#blockcheckDomainInput").val().trim();
            if (!domain) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("Warning") }}',
                    message: '{{ lang._("Please enter a blocked domain name.") }}'
                });
                return;
            }
            $("#blockcheckBtn_progress").addClass("fa fa-spinner fa-pulse");
            $("#blockcheckSummary").html('<em>Running blockcheck against ' + $('<div>').text(domain).html() +
                '… this takes 1–3 minutes. Don\'t close this page.</em>');
            $("#blockcheckWinning").html('');
            $("#blockcheckRaw").text('');

            // Bypass OPNsense's ajaxCall (which has a short default timeout)
            // and call $.ajax directly with a 10-minute timeout — blockcheck2
            // takes 1–3 minutes for a standard scan and we'd rather wait than
            // give the user the misleading "Unstructured output" fallback.
            var doneFn = function(data, status) {
                $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");

                if (!data || data.status !== 'ok') {
                    $("#blockcheckSummary").html('<span class="text-danger">' +
                        $('<div>').text("Error: " + (data.message || 'Unknown error')).html() + '</span>');
                    return;
                }

                // data.result is JSON-as-string from blockcheck.sh. Parse it.
                var bc = tryJSON(data.result);
                if (!bc) {
                    // Old wrapper or unexpected output — just dump it
                    $("#blockcheckSummary").html('<em>Unstructured output:</em>');
                    $("#blockcheckRaw").text(data.result || '(empty)');
                    return;
                }

                if (bc.status === 'error') {
                    $("#blockcheckSummary").html('<span class="text-danger">' +
                        $('<div>').text("Blockcheck error: " + bc.message).html() + '</span>');
                    if (bc.log) $("#blockcheckRaw").text(bc.log);
                    return;
                }

                // Detect the "site is not censored from this firewall" case.
                // blockcheck2 reports lines like "... : working without bypass"
                // when the baseline test (no DPI evasion) already succeeds.
                // Picking such a line as a strategy makes no sense — surface
                // a clear explanation instead of asking the user to copy it.
                var winning = (bc.winning || []).filter(function(l){ return l.trim() !== ''; });
                var allBaseline = winning.length > 0 && winning.every(function(l){
                    return /working without bypass/i.test(l);
                });

                var domEsc = $('<div>').text(bc.domain).html();

                if (allBaseline) {
                    $("#blockcheckSummary").html(
                        '<span class="text-success"><strong>' + domEsc + '</strong> reaches its server fine from this firewall ' +
                        'without any DPI bypass.</span><br>' +
                        'This means either (a) your ISP does not block this domain, or (b) your firewall\'s DNS resolver ' +
                        '(e.g. AdGuard, Unbound DoH) is already bypassing a DNS-based block. ' +
                        'If LAN clients still cannot reach it, the issue is on the client side — usually because clients ' +
                        'are using their own DNS instead of this firewall. Try a domain you know is blocked at the TLS/SNI ' +
                        'layer to find a useful strategy.'
                    );
                } else {
                    $("#blockcheckSummary").html('Tested <strong>' + domEsc +
                        '</strong>. Strategies that worked are listed below — copy one into the HTTPS Strategy field on the Settings page.');
                }

                // List winning strategies
                var html = '';
                if (winning.length > 0) {
                    html = '<ul style="font-family: monospace; font-size: 12px;">';
                    winning.forEach(function(line) {
                        html += '<li>' + $('<div>').text(line).html() + '</li>';
                    });
                    html += '</ul>';
                } else {
                    html = '<em>No working strategies found in the standard test set. Try a different domain or run blockcheck2 manually via SSH for a custom search.</em>';
                }
                $("#blockcheckWinning").html(html);

                // Full summary in raw box
                $("#blockcheckRaw").text(bc.summary || '');
            };

            var errFn = function(jqXHR, textStatus, errorThrown) {
                $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                var msg = (textStatus === 'timeout')
                    ? 'Blockcheck took longer than 10 minutes and was cancelled. Try a single domain at a time or a faster ISP.'
                    : 'Request failed: ' + textStatus;
                $("#blockcheckSummary").html('<span class="text-danger">' +
                    $('<div>').text(msg).html() + '</span>');
            };

            // Form-encoded POST so OPNsense's ApiControllerBase->getPost() works.
            $.ajax({
                type: 'POST',
                url: '/api/zapret/diagnostics/blockcheck',
                data: {'domain': domain},
                dataType: 'json',
                timeout: 600000,   // 10 minutes — match the configd action's timeout
                success: doneFn,
                error: errFn
            });
        });
    });
</script>

<section class="page-content-main">
    <div class="container-fluid">
        <div class="row">
            <section class="col-xs-12">
                <div class="content-box">
                    <div class="content-box-header">
                        <h3>{{ lang._('Test Domain Connectivity') }}</h3>
                    </div>
                    <div class="content-box-main">
                        <div class="table-responsive">
                            <table class="table table-striped">
                                <tbody>
                                    <tr>
                                        <td style="width: 200px;">{{ lang._('Domain') }}</td>
                                        <td>
                                            <input type="text" class="form-control" id="testDomainInput" placeholder="example.com"/>
                                        </td>
                                        <td style="width: 150px;">
                                            <button class="btn btn-primary" id="testDomainBtn" type="button">
                                                {{ lang._('Test') }} <i id="testDomainBtn_progress"></i>
                                            </button>
                                        </td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                        <div class="col-md-12">
                            <pre id="testDomainResult" style="max-height: 300px; overflow-y: auto; white-space: pre-wrap;">{{ lang._('Enter a domain and click Test to check HTTPS connectivity.') }}</pre>
                        </div>
                    </div>
                </div>
            </section>
        </div>
        <div class="row">
            <section class="col-xs-12">
                <div class="content-box">
                    <div class="content-box-header">
                        <h3>{{ lang._('Blockcheck (Strategy Finder)') }}</h3>
                    </div>
                    <div class="content-box-main">
                        <div class="table-responsive">
                            <table class="table table-striped">
                                <tbody>
                                    <tr>
                                        <td style="width: 200px;">{{ lang._('Blocked Domain') }}</td>
                                        <td>
                                            <input type="text" class="form-control" id="blockcheckDomainInput" placeholder="rutracker.org"/>
                                        </td>
                                        <td style="width: 150px;">
                                            <button class="btn btn-primary" id="blockcheckBtn" type="button">
                                                {{ lang._('Run') }} <i id="blockcheckBtn_progress"></i>
                                            </button>
                                        </td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                        <div class="col-md-12" style="padding-top: 10px;">
                            <div id="blockcheckSummary">
                                {{ lang._('Enter a domain that your ISP currently blocks and click Run. Blockcheck will spend 1–3 minutes testing many DPI bypass strategies and report which ones successfully reach the site. Copy a working strategy into the HTTPS Strategy field on the Settings page.') }}
                            </div>
                            <div id="blockcheckWinning" style="padding-top: 10px;"></div>
                            <details style="padding-top: 10px;">
                                <summary>{{ lang._('Full output (advanced)') }}</summary>
                                <pre id="blockcheckRaw" style="max-height: 400px; overflow-y: auto; white-space: pre-wrap; font-size: 11px;"></pre>
                            </details>
                        </div>
                    </div>
                </div>
            </section>
        </div>
    </div>
</section>
