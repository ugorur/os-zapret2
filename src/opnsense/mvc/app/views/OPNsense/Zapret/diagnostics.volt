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
    $(document).ready(function() {
        // Test Domain
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

        // Blockcheck
        $("#blockcheckBtn").click(function() {
            var domain = $("#blockcheckDomainInput").val().trim();
            if (!domain) {
                BootstrapDialog.show({
                    type: BootstrapDialog.TYPE_WARNING,
                    title: '{{ lang._("Warning") }}',
                    message: '{{ lang._("Please enter a domain name.") }}'
                });
                return;
            }
            $("#blockcheckBtn_progress").addClass("fa fa-spinner fa-pulse");
            $("#blockcheckResult").text("Running blockcheck2... This may take a few minutes.");
            ajaxCall('/api/zapret/diagnostics/blockcheck', {'domain': domain}, function(data, status) {
                $("#blockcheckBtn_progress").removeClass("fa fa-spinner fa-pulse");
                if (data.status === 'ok') {
                    $("#blockcheckResult").text(data.result);
                } else {
                    $("#blockcheckResult").text("Error: " + (data.message || "Unknown error"));
                }
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
                                        <td style="width: 200px;">{{ lang._('Domain') }}</td>
                                        <td>
                                            <input type="text" class="form-control" id="blockcheckDomainInput" placeholder="example.com"/>
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
                        <div class="col-md-12">
                            <pre id="blockcheckResult" style="max-height: 500px; overflow-y: auto; white-space: pre-wrap;">{{ lang._('Enter a blocked domain and click Run to test which DPI bypass strategies work against your ISP. This may take several minutes.') }}</pre>
                        </div>
                    </div>
                </div>
            </section>
        </div>
    </div>
</section>
