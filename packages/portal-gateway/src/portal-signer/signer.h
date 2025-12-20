#pragma once

#include <stddef.h>
#include "config.h"
#include "crypto_hmac.h"

/* Handle one incoming HTTP connection (TCP). */
void portal_signer_handle_client(int cfd, const signer_config_t *cfg);
