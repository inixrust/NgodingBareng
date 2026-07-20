# MySQL menolak file konfigurasi yang world-writable dan diam-diam
# mengabaikannya. Bind mount dari Windows/Docker Desktop selalu ber-mode 0777,
# jadi konfigurasi harus dipanggang ke dalam image dengan permission yang benar.
ARG MYSQL_VERSION=8.4
FROM mysql:${MYSQL_VERSION}

COPY --chown=root:root --chmod=0644 conf.d/app.cnf /etc/mysql/conf.d/app.cnf
