#!/bin/sh

set -eu

APACHE_FOLDER="/etc/apache2/sites-available"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <nom_projet> <emplacement>"
    exit 1
fi

PROJECT_NAME="$1"
LOCATION="$(realpath "$2")"

PROJECT_PATH="${LOCATION%/}/${PROJECT_NAME}"

SERVER_NAME="${PROJECT_NAME}.cfpt.loc"

APACHE_VHOST_FILENAME="${PROJECT_NAME}.cfpt.conf"
APACHE_VHOST_FILE="${APACHE_FOLDER}/${APACHE_VHOST_FILENAME}"

NGINX_VHOST_FILENAME="${PROJECT_NAME}.cfpt.conf"
NGINX_VHOST_FILE="${NGINX_AVAILABLE}/${NGINX_VHOST_FILENAME}"
NGINX_VHOST_LINK="${NGINX_ENABLED}/${NGINX_VHOST_FILENAME}"

PROJECT_EXISTS=false
APACHE_VHOST_EXISTS=false
NGINX_VHOST_EXISTS=false

EXISTING_APACHE_VHOST=""
EXISTING_NGINX_VHOST=""

APACHE_INSTALLED=false
NGINX_INSTALLED=false

if command -v apache2ctl >/dev/null 2>&1; then
    APACHE_INSTALLED=true
fi

if command -v nginx >/dev/null 2>&1; then
    NGINX_INSTALLED=true
fi

if [ "$APACHE_INSTALLED" = false ] && [ "$NGINX_INSTALLED" = false ]; then
    echo "❌ Aucun serveur web Apache ou Nginx n'est installé."
    exit 1
fi

echo "Serveurs détectés :"

if [ "$APACHE_INSTALLED" = true ]; then
    echo "  ✅ Apache"
fi

if [ "$NGINX_INSTALLED" = true ]; then
    echo "  ✅ Nginx"
fi

if [ -d "$PROJECT_PATH" ]; then
    PROJECT_EXISTS=true
fi

if [ "$APACHE_INSTALLED" = true ] && [ -d "$APACHE_FOLDER" ]; then

    for file in "$APACHE_FOLDER"/*.conf; do
        [ -f "$file" ] || continue

        if grep -qE "^[[:space:]]*ServerName[[:space:]]+${SERVER_NAME}[[:space:]]*$" "$file"; then
            APACHE_VHOST_EXISTS=true
            EXISTING_APACHE_VHOST="$file"
            break
        fi
    done

fi

if [ "$NGINX_INSTALLED" = true ] && [ -d "$NGINX_AVAILABLE" ]; then

    for file in "$NGINX_AVAILABLE"/*; do
        [ -f "$file" ] || continue

        if grep -qE "^[[:space:]]*server_name[[:space:]]+[^;]*${SERVER_NAME}[^;]*;" "$file"; then
            NGINX_VHOST_EXISTS=true
            EXISTING_NGINX_VHOST="$file"
            break
        fi
    done

fi

if [ "$PROJECT_EXISTS" = true ] ||
   [ "$APACHE_VHOST_EXISTS" = true ] ||
   [ "$NGINX_VHOST_EXISTS" = true ]; then

    echo ""
    echo "⚠️ Des éléments existants ont été détectés."

    if [ "$PROJECT_EXISTS" = true ]; then
        echo "  📁 Projet : $PROJECT_PATH"
    fi

    if [ "$APACHE_VHOST_EXISTS" = true ]; then
        echo "  🌐 Apache : $EXISTING_APACHE_VHOST"
    fi

    if [ "$NGINX_VHOST_EXISTS" = true ]; then
        echo "  🌐 Nginx  : $EXISTING_NGINX_VHOST"
    fi

    echo ""

    printf "Voulez-vous supprimer les éléments existants et recréer le projet ? (y/n) "
    read yn

    case "$yn" in

        [Yy]*)

            echo ""
            echo "Suppression des éléments existants..."

            if [ "$PROJECT_EXISTS" = true ]; then
                echo "📁 Suppression du projet..."
                rm -rf "$PROJECT_PATH"
            fi

            if [ "$APACHE_VHOST_EXISTS" = true ]; then

                echo "🌐 Suppression du VHost Apache..."

                APACHE_NAME="$(basename "$EXISTING_APACHE_VHOST")"

                sudo a2dissite "$APACHE_NAME" \
                    >/dev/null 2>&1 || true

                sudo rm -f "$EXISTING_APACHE_VHOST"
            fi

            if [ "$NGINX_VHOST_EXISTS" = true ]; then

                echo "🌐 Suppression du server block Nginx..."

                NGINX_NAME="$(basename "$EXISTING_NGINX_VHOST")"

                if [ -L "$NGINX_ENABLED/$NGINX_NAME" ]; then
                    sudo rm -f "$NGINX_ENABLED/$NGINX_NAME"
                fi

                sudo rm -f "$EXISTING_NGINX_VHOST"
            fi

            echo "✅ Nettoyage terminé."
            ;;

        [Nn]*)
            echo "Abandon de la création du projet."
            exit 1
            ;;

        *)
            echo "Réponse invalide."
            exit 1
            ;;

    esac
fi

mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH" || exit 1

composer init \
    --type="project" \
    --license="MIT" \
    --stability="stable" \
    --require="slim/slim:4.*" \
    --require="slim/psr7:^1.7" \
    --require="nyholm/psr7:^1.8" \
    --require="nyholm/psr7-server:^1.1" \
    --require="guzzlehttp/psr7:^2" \
    --require="laminas/laminas-diactoros:^3.6" \
    --require="slim/php-view:^3.4" \
    --require="fakerphp/faker:^1.24"

COMPOSER_NAME=$(php -r '
    $composer = json_decode(file_get_contents("composer.json"), true);
    echo $composer["name"] ?? "";
')

if [ -z "$COMPOSER_NAME" ]; then
    echo "Erreur : impossible de récupérer le nom du projet depuis composer.json"
    exit 1
fi

COMPOSER_VENDOR="${COMPOSER_NAME%%/*}"
COMPOSER_PROJECT="${COMPOSER_NAME#*/}"

to_namespace()
{
    printf '%s' "$1" |
        sed -E 's/[^a-zA-Z0-9]+/ /g' |
        awk '{
            for (i = 1; i <= NF; i++)
                printf "%s", toupper(substr($i, 1, 1)) substr($i, 2)
        }'
}

NAMESPACE_VENDOR=$(to_namespace "$COMPOSER_VENDOR")
NAMESPACE_PROJECT=$(to_namespace "$COMPOSER_PROJECT")

PROJECT_NAMESPACE="${NAMESPACE_VENDOR}\\${NAMESPACE_PROJECT}"

echo "Composer name: $COMPOSER_NAME"
echo "PHP namespace: ${PROJECT_NAMESPACE}\\"

php -r '
    $file = "composer.json";
    $composer = json_decode(file_get_contents($file), true);

    $composer["autoload"]["files"] ??= [];

    if (!in_array("helpers.php", $composer["autoload"]["files"], true)) {
        $composer["autoload"]["files"][] = "helpers.php";
    }

    file_put_contents(
        $file,
        json_encode($composer, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
    );
'

composer dump-autoload

composer install

mkdir -p public src routes views config

mkdir -p views/errors src/Controllers src/Middleware src/Models src/Services src/Core 

if [ "$APACHE_INSTALLED" = true ]; then

    echo ""
    echo "🌐 Configuration Apache..."

    sudo tee "$APACHE_VHOST_FILE" >/dev/null <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}

    ServerAdmin webmaster@localhost
    DocumentRoot ${PROJECT_PATH}/public

    <Directory ${PROJECT_PATH}/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${SERVER_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SERVER_NAME}-access.log combined
</VirtualHost>
EOF

    echo "✅ VHost Apache créé :"
    echo "   $APACHE_VHOST_FILE"

    sudo a2ensite "$APACHE_VHOST_FILENAME" >/dev/null

    if sudo apache2ctl -t; then
        echo "✅ Configuration Apache valide."
        sudo systemctl reload apache2
        echo "✅ Apache rechargé."
    else
        echo "❌ Erreur dans la configuration Apache."

        sudo a2dissite "$APACHE_VHOST_FILENAME" \
            >/dev/null 2>&1 || true

        sudo rm -f "$APACHE_VHOST_FILE"

        exit 1
    fi

elif [ "$NGINX_INSTALLED" = true ]; then

    echo ""
    echo "🌐 Configuration Nginx..."

    sudo tee "$NGINX_VHOST_FILE" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${SERVER_NAME};

    root ${PROJECT_PATH}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }

    access_log /var/log/nginx/${SERVER_NAME}-access.log;
    error_log /var/log/nginx/${SERVER_NAME}-error.log;
}
EOF

    echo "✅ Server block Nginx créé :"
    echo "   $NGINX_VHOST_FILE"

    if [ -e "$NGINX_VHOST_LINK" ] || [ -L "$NGINX_VHOST_LINK" ]; then
        sudo rm -f "$NGINX_VHOST_LINK"
    fi

    sudo ln -s "$NGINX_VHOST_FILE" "$NGINX_VHOST_LINK"

    if sudo nginx -t; then
        echo "✅ Configuration Nginx valide."
        sudo systemctl reload nginx
        echo "✅ Nginx rechargé."
    else
        echo "❌ Erreur dans la configuration Nginx."

        sudo rm -f "$NGINX_VHOST_LINK"
        sudo rm -f "$NGINX_VHOST_FILE"

        exit 1
    fi

fi

cat > config/database.sample.php <<'EOF'
<?php

define('DB_HOST', 'localhost');
define('DB_NAME', '');
define('DB_CHARSET', 'utf8mb4');
define('DB_USER', '');
define('DB_PASSWORD', '');
EOF

cat > public/.htaccess <<'EOF'
Options All -Indexes

<IfModule mod_rewrite.c>
RewriteEngine On

RewriteCond %{REQUEST_FILENAME} !-d
RewriteCond %{REQUEST_FILENAME} !-f
RewriteRule ^ index.php [QSA,L]
</IfModule>
EOF

cat > public/index.php <<'EOF'
<?php

use Slim\Factory\AppFactory;
use Slim\Exception\HttpNotFoundException;
use Slim\Views\PhpRenderer;

require __DIR__ . '/../vendor/autoload.php';

session_start();

$app = AppFactory::create();

$errorMiddleware = $app->addErrorMiddleware(true, true, true);

$errorMiddleware->setErrorHandler(
Slim\Exception\HttpNotFoundException::class,
function ($request, $exception, $displayErrorDetails) {
$response = new \Slim\Psr7\Response();
$view = new PhpRenderer(__DIR__ . '/../views');
$view->setLayout("layout.php");
return $view->render($response->withStatus(404), 'errors/404.php', [
    'withMenu' => false,
    'title' => 'Page non trouvée',
    'message' => $exception->getMessage(),
]);
}
);

$errorMiddleware->setErrorHandler(
Slim\Exception\HttpInternalServerErrorException::class,
function ($request, $exception, $displayErrorDetails) {
$response = new \Slim\Psr7\Response();
$view = new PhpRenderer(__DIR__ . '/../views');
$view->setLayout("layout.php");
return $view->render($response->withStatus(500), 'errors/500.php', [
    'withMenu' => false,
    'title' => 'Erreur interne du serveur',
    'message' => $exception->getMessage(),
]);
}
);

require __DIR__ . '/../routes/web.php';

$app->run();
EOF

cat > routes/web.php <<'EOF'
<?php

// $app->get('/', [Controller_Class::class, 'Func Name'])
// ->add(new Middleware_Class())
EOF

cat > src/Controllers/BaseController.php <<EOF
<?php

namespace ${PROJECT_NAMESPACE}\Controllers;

use TheWallet\Services\UserService;
use Slim\Views\PhpRenderer;

abstract class BaseController
{
    /**
     * @var PhpRenderer
     */
    protected PhpRenderer \$view;

    /**
     * Constructor
     */
    public function __construct()
    {
        \$this->view = new PhpRenderer(__DIR__ . '/../../views', [
            'title' => 'The Wallet',
            'withMenu' => true,
        ]);

        \$this->view->setLayout("layout.php");
    }
}
EOF

cat > src/Core/Database.php <<EOF
<?php

declare(strict_types=1);

namespace ${PROJECT_NAMESPACE}\Core;

require_once __DIR__ . '/../../config/database.php';

use PDO;

class Database
{
    /**
     * Open a new database connection if needed, returns the current connection
     *
     * @return PDO
     */
    public static function connection(): PDO
    {
        static \$pdo = null;

        if (\$pdo === null) {
            try {
                \$dsn = 'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=' . DB_CHARSET;

                \$options = [
                    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_EMULATE_PREPARES => false,
                ];

                \$pdo = new PDO(\$dsn, DB_USER, DB_PASSWORD, \$options);
            } catch (\Throwable \$th) {
                die("Can't connect to database");
            }
        }

        return \$pdo;
    }
}
EOF

cat > src/Models/AbstractModel.php <<EOF
<?php

declare(strict_types=1);

namespace ${PROJECT_NAMESPACE}\Models;

abstract class AbstractModel
{
    /**
     * Defines primary key
     *
     * @var string
     */
    protected static ?string \$primaryKey = null;

    /**
     * Allow to casts properties
     *
     * @var array
     */
    protected array \$casts = [];

    /**
     * Assign values to properties
     *
     * @param array \$attributes
     * @return self
     */
    public function fill(array \$attributes): self
    {
        foreach (\$attributes as \$property => \$value) {
            if (property_exists(\$this, \$property)) {
                if (array_key_exists(\$property, \$this->casts)) {
                    if (\$this->casts[\$property] === 'float') {
                        \$this->\$property = (float)\$value;
                    } elseif (\$this->casts[\$property] === 'datetime') {
                        \$this->\$property = new \DateTime(\$value);
                    } else {
                        throw new \InvalidArgumentException("Unsupported cast type");
                    }
                } else {
                    \$this->\$property = \$value;
                }
            }
        }

        return \$this;
    }


    /**
     * Create a new row
     *
     * @param array \$attributes
     * @return self
     */
    public static function create(array \$attributes): self
    {
        \$primaryKey = static::\$primaryKey;

        if (!\$primaryKey) {
            throw new \LogicException("Primary key name must be set");
        }

        if (array_key_exists(\$primaryKey, \$attributes)) {
            throw new \LogicException("Primary key property must be null");
        }

        \$model = (new static())->fill(\$attributes);

        \$model->save();

        return \$model;
    }

    /**
     * Save Model
     */
    public function save(): bool
    {
        \$primaryKey = static::\$primaryKey;

        if (!\$primaryKey) {
            throw new \LogicException("Primary key name must be set");
        }

        if (\$this->\$primaryKey === null) {
            return \$this->insert();
        }

        return \$this->update();
    }

    /**
     * insert a new row
     *
     * @return bool
     */
    abstract public function insert(): bool;

    /**
     * update an existing row
     *
     * @return bool
     */
    abstract public function update(): bool;
}
EOF

cat > views/errors/404.php <<'EOF'
<h1>404 - Page non trouvée</h1>
<p><?= $message ?></p>
EOF

cat > views/errors/500.php <<'EOF'
<h1>500 - Erreur interne du serveur</h1>
<p><?= $message ?></p>
EOF

cat > views/layout.php <<'EOF'
<!doctype html>
<html lang="fr">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title><?= $title ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB" crossorigin="anonymous">
    </head>
    <body>
        <?php if ($withMenu) {
            echo $this->fetch('menu.php');
        } ?>
        <?= $content ?>
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js" integrity="sha384-FKyoEForCGlyvwx9Hj09JcYn3nv7wiPVlz7YYwJrWVcXK/BmnVDxM+D2scQbITxI" crossorigin="anonymous"></script>
    </body>
</html>
EOF

cat > views/menu.php <<'EOF'
<nav class="navbar navbar-expand-lg navbar-light bg-light">
    <div class="container-fluid">
        <a class="navbar-brand" href="#">Slim App</a>
        <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav" aria-controls="navbarNav" aria-expanded="false" aria-label="Toggle navigation">
            <span class="navbar-toggler-icon"></span>
        </button>
        <div class="collapse navbar-collapse" id="navbarNav">
            <ul class="navbar-nav">
                <li class="nav-item">
                    <a class="nav-link active" aria-current="page" href="/">Home</a>
                </li>
            </ul>
        </div>
    </div>
</nav>
EOF

cat > helpers.php <<'EOF'
<?php

declare(strict_types=1);

/**
 * Escape a value
 *
 * @param mixed $value
 * @return string
 */
function escape(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}
EOF