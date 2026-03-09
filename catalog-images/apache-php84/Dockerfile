# Workload Catalog Image: apache-php84
# Apache 2.4 + PHP 8.4 — for Starter (shared pod) and Business/Premium (dedicated pod)
# Built by CI, scanned by Trivy, pushed to Harbor as catalog/apache-php84:<version>-<date>

FROM php:8.4-apache-alpine

# Install common PHP extensions required by most web apps
RUN apk add --no-cache \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libzip-dev \
    oniguruma-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        gd \
        mysqli \
        pdo_mysql \
        opcache \
        zip \
        mbstring \
        exif \
        intl \
    && apk del freetype-dev libjpeg-turbo-dev libpng-dev

# Enable Apache mod_rewrite (required by WordPress, Laravel, etc.)
RUN a2enmod rewrite headers

# Harden PHP configuration
COPY php.ini /usr/local/etc/php/conf.d/platform.ini

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/healthz || exit 1

COPY healthz.php /var/www/html/healthz.php

# Run as non-root where possible
# Note: Apache requires root to bind port 80; drops privileges after binding
EXPOSE 80

# Log to stdout/stderr for Loki collection
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
    && ln -sf /dev/stderr /var/log/apache2/error.log

# Client files mount point
VOLUME ["/var/www/html"]
