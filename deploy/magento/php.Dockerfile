# PHP-FPM for Magento 2.4 with the required extensions. Composer is included
# for installing Magento; Marketplace keys are passed only at install time
# (COMPOSER_AUTH) and are never stored in the image.
FROM php:8.3-fpm-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libicu-dev \
      libxslt1-dev libzip-dev unzip git curl \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j"$(nproc)" bcmath gd intl pdo_mysql soap xsl zip sockets opcache ftp \
 && pecl install redis \
 && docker-php-ext-enable redis \
 && apt-get purge -y --auto-remove \
 && rm -rf /var/lib/apt/lists/* /tmp/pear

COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer
COPY php.ini /usr/local/etc/php/conf.d/zz-magento.ini

RUN mkdir -p /var/www/magento /var/www/.composer \
 && chown -R www-data:www-data /var/www
ENV COMPOSER_HOME=/var/www/.composer
WORKDIR /var/www/magento
USER www-data
