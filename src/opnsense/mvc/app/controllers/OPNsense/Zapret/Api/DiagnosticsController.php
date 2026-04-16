<?php

/**
 *    Copyright (C) 2026 Umur Gorur
 *    All rights reserved.
 *
 *    Redistribution and use in source and binary forms, with or without
 *    modification, are permitted provided that the following conditions are met:
 *
 *    1. Redistributions of source code must retain the above copyright notice,
 *       this list of conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *
 *    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 *    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 *    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 *    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 *    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *    POSSIBILITY OF SUCH DAMAGE.
 */

namespace OPNsense\Zapret\Api;

use OPNsense\Base\ApiControllerBase;

class DiagnosticsController extends ApiControllerBase
{
    /**
     * Test connectivity to a domain
     * @return array result
     */
    public function testdomainAction()
    {
        if ($this->request->isPost()) {
            $domain = $this->request->getPost('domain', 'striptags', '');
            if (!empty($domain) && preg_match('/^[a-zA-Z0-9\.\-]+$/', $domain)) {
                $backend = new \OPNsense\Core\Backend();
                $response = $backend->configdpRun('zapret testdomain', [$domain]);
                return ['status' => 'ok', 'result' => $response];
            }
            return ['status' => 'error', 'message' => 'Invalid domain name.'];
        }
        return ['status' => 'error', 'message' => 'POST required.'];
    }

    /**
     * Run blockcheck against a domain. blockcheck2 takes 1–3 minutes, which
     * exceeds PHP's default max_execution_time (30s) and our configdpRun
     * call would otherwise be killed mid-flight, returning an empty body to
     * the caller. We bump both before invoking configd.
     * @return array result
     */
    public function blockcheckAction()
    {
        if ($this->request->isPost()) {
            $domain = $this->request->getPost('domain', 'striptags', '');
            if (!empty($domain) && preg_match('/^[a-zA-Z0-9\.\-]+$/', $domain)) {
                // 10 minutes — match the wrapper's internal timeout. set_time_limit
                // resets the PHP execution clock from "now"; without it, the request
                // dies at 30s and the user sees "Unstructured output: (empty)".
                @set_time_limit(700);
                $backend = new \OPNsense\Core\Backend();
                // configdpRun signature: ($event, $params, $detach, $timeout, $connect_timeout)
                // Default timeout is 120s — too short for blockcheck. Pass 650.
                $response = $backend->configdpRun('zapret blockcheck', [$domain], false, 650);
                return ['status' => 'ok', 'result' => $response];
            }
            return ['status' => 'error', 'message' => 'Invalid domain name.'];
        }
        return ['status' => 'error', 'message' => 'POST required.'];
    }
}
