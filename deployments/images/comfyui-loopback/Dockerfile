FROM nginxinc/nginx-unprivileged:1.27-alpine

# The loopback proxy creates an Apache MD5 htpasswd entry at startup.  The
# upstream unprivileged image intentionally does not include OpenSSL, so make
# that dependency explicit instead of allowing a failed command substitution
# to yield an empty password hash.
USER root
RUN apk add --no-cache openssl
USER 101
