# Tier application : php-fpm, utilisateur non-root, code embarqué dans l'image
# (3 conteneurs identiques, immuables)
FROM php:8.4.27-fpm-alpine
RUN docker-php-ext-install -j"$(nproc)" pdo_mysql \
 && rm -f /usr/local/etc/php-fpm.d/www.conf.default /usr/local/etc/php-fpm.d/zz-docker.conf
COPY php/php.ini  /usr/local/etc/php/conf.d/90-projet7.ini
COPY php/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY --chown=root:root --chmod=0644 src/ /var/www/html/
USER www-data
EXPOSE 9000
