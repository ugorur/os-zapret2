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
        var data_get_map = {'frm_GeneralSettings': '/api/zapret/settings/get'};
        mapDataToFormUI(data_get_map).done(function(data) {
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        updateServiceControlUI('zapret');

        // Save settings
        $("#saveAct").click(function() {
            saveFormToEndpoint('/api/zapret/settings/set', 'frm_GeneralSettings', function() {
                $("#saveAct_progress").addClass("fa fa-spinner fa-pulse");
                ajaxCall('/api/zapret/service/reconfigure', {}, function(data, status) {
                    updateServiceControlUI('zapret');
                    $("#saveAct_progress").removeClass("fa fa-spinner fa-pulse");
                });
            });
        });

        // Setup service control
        $("#zapret\\.btn_start").click(function() {
            $("#zapret\\.btn_start_progress").addClass("fa fa-spinner fa-pulse");
            ajaxCall('/api/zapret/service/start', {}, function(data, status) {
                updateServiceControlUI('zapret');
                $("#zapret\\.btn_start_progress").removeClass("fa fa-spinner fa-pulse");
            });
        });
        $("#zapret\\.btn_stop").click(function() {
            $("#zapret\\.btn_stop_progress").addClass("fa fa-spinner fa-pulse");
            ajaxCall('/api/zapret/service/stop', {}, function(data, status) {
                updateServiceControlUI('zapret');
                $("#zapret\\.btn_stop_progress").removeClass("fa fa-spinner fa-pulse");
            });
        });
        $("#zapret\\.btn_restart").click(function() {
            $("#zapret\\.btn_restart_progress").addClass("fa fa-spinner fa-pulse");
            ajaxCall('/api/zapret/service/restart', {}, function(data, status) {
                updateServiceControlUI('zapret');
                $("#zapret\\.btn_restart_progress").removeClass("fa fa-spinner fa-pulse");
            });
        });
    });
</script>

<div class="content-box" style="padding: 10px;">
    <div class="col-md-12">
        <div id="zapret" class="btn-group">
            <button class="btn btn-default" id="zapret.btn_start" data-service-widget="zapret" data-service-action="start" data-service-id="zapret" type="button">
                <b>{{ lang._('Start') }}</b> <i id="zapret.btn_start_progress"></i>
            </button>
            <button class="btn btn-default" id="zapret.btn_restart" data-service-widget="zapret" data-service-action="restart" data-service-id="zapret" type="button">
                <b>{{ lang._('Restart') }}</b> <i id="zapret.btn_restart_progress"></i>
            </button>
            <button class="btn btn-default" id="zapret.btn_stop" data-service-widget="zapret" data-service-action="stop" data-service-id="zapret" type="button">
                <b>{{ lang._('Stop') }}</b> <i id="zapret.btn_stop_progress"></i>
            </button>
        </div>
        <div id="zapret_status" class="btn-group" style="margin-left: 10px;">
        </div>
    </div>
</div>

<section class="page-content-main">
    <div class="container-fluid">
        <div class="row">
            <section class="col-xs-12">
                <div class="tab-content content-box col-xs-12 __mb">
                    {{ partial("layout_partials/base_form", ['fields': generalForm, 'id': 'frm_GeneralSettings']) }}
                </div>
            </section>
        </div>
    </div>
</section>

<section class="page-content-main">
    <div class="container-fluid">
        <div class="row">
            <section class="col-xs-12">
                <div class="content-box">
                    <div class="col-md-12">
                        <br/>
                        <button class="btn btn-primary" id="saveAct" type="button">
                            <b>{{ lang._('Save') }}</b> <i id="saveAct_progress"></i>
                        </button>
                        <br/><br/>
                    </div>
                </div>
            </section>
        </div>
    </div>
</section>
