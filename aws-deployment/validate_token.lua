local ffi = require "ffi"
local C = ffi.C

ffi.cdef[[
    typedef struct engine_st ENGINE;
    typedef struct evp_md_st EVP_MD;
    typedef struct evp_md_ctx_st EVP_MD_CTX;

    const EVP_MD *EVP_sha256(void);
    unsigned char *HMAC(
        const EVP_MD *evp_md,
        const void *key, int key_len,
        const unsigned char *data, size_t data_len,
        unsigned char *md, unsigned int *md_len
    );
]]

local secret = "4cce76554d5790b5bef03c915e01d01ab8b5ba7bd3ff9ba37596626303c8ce52"

local token = ngx.var.arg_token
if not token or token == "" then
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Access-Control-Allow-Origin"] = ngx.var.allow_origin
    ngx.say('{"code":"Forbidden","message":"Missing token"}')
    return ngx.exit(403)
end

local window_seconds = 600
local window = math.floor(ngx.time() / window_seconds)

local function compute(w)
    local msg = tostring(w)
    local md_len = ffi.new("unsigned int[1]")
    local md = C.HMAC(C.EVP_sha256(), secret, #secret, msg, #msg, nil, md_len)
    local raw = ffi.string(md, md_len[0])
    local b64 = ngx.encode_base64(raw)
    b64 = b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    return b64
end

if token ~= compute(window) and token ~= compute(window - 1) then
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Access-Control-Allow-Origin"] = ngx.var.allow_origin
    ngx.say('{"code":"Forbidden","message":"Invalid token"}')
    return ngx.exit(403)
end

-- strip token from args before proxying
local args = ngx.var.args or ""
args = args:gsub("[&?]?token=[^&]*", "")
args = args:gsub("^&", "")
ngx.var.args = args
