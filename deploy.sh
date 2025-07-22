#!/bin/bash

# Exit on error
set -e

echo "🚀 Starting deployment process..."

# Function to check if docker compose command exists and use appropriate version
check_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

DOCKER_COMPOSE=$(check_docker_compose)

# Ensure .env.production exists
if [ ! -f ".env.production" ]; then
    echo "❌ Error: .env.production file not found!"
    echo "Please create .env.production with your production configuration."
    exit 1
fi

# Load environment variables
export $(cat .env.production | grep -v '^#' | xargs)

# Validate required environment variables
if [ -z "$SECRET_KEY_BASE" ]; then
    echo "❌ Error: SECRET_KEY_BASE is not set in .env.production"
    echo "Generate one with: openssl rand -hex 64"
    exit 1
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "❌ Error: POSTGRES_PASSWORD is not set in .env.production"
    exit 1
fi

echo "🔍 Checking current deployment status..."
if $DOCKER_COMPOSE ps | grep -q "maybe.*Up"; then
    echo "📊 Current deployment is running. Performing rolling update..."
    ROLLING_UPDATE=true
else
    echo "🆕 No current deployment found. Performing fresh deployment..."
    ROLLING_UPDATE=false
fi

# Pull latest images if using remote registry
echo "📦 Pulling any updated base images..."
$DOCKER_COMPOSE pull --ignore-pull-failures || true

# Build new images without affecting running containers
echo "🏗️  Building new images..."
$DOCKER_COMPOSE build --no-cache web

# If this is a rolling update, create temporary containers to test
if [ "$ROLLING_UPDATE" = true ]; then
    echo "🔄 Testing new build before switching..."
    
    # Start database if not running
    $DOCKER_COMPOSE up -d db
    
    # Wait for database to be ready
    echo "⏳ Waiting for database to be ready..."
    timeout 60s bash -c 'until docker exec $(docker-compose ps -q db) pg_isready -U ${POSTGRES_USER:-postgres}; do sleep 2; done'
    
    # Test the new build by running database migrations
    echo "🔍 Testing database migrations..."
    $DOCKER_COMPOSE run --rm web bundle exec rails db:migrate:status
    
    echo "✅ Build test successful! Proceeding with deployment..."
fi

# Perform the actual deployment
echo "🔄 Swapping to new containers..."
$DOCKER_COMPOSE up -d --force-recreate

# Wait for services to be healthy
echo "⏳ Waiting for services to be healthy..."
timeout 120s bash -c '
    while true; do
        if docker exec $(docker-compose ps -q db) pg_isready -U ${POSTGRES_USER:-postgres} > /dev/null 2>&1; then
            echo "✅ Database is ready"
            break
        fi
        echo "⏳ Waiting for database..."
        sleep 5
    done
'

# Wait for web service to respond
echo "⏳ Waiting for web service to respond..."
timeout 120s bash -c '
    while true; do
        if curl -f http://localhost:${PORT:-2400}/health > /dev/null 2>&1; then
            echo "✅ Web service is responding"
            break
        fi
        if docker logs $(docker-compose ps -q web) 2>&1 | tail -5 | grep -i "listening\|started\|ready"; then
            echo "✅ Web service appears to be started"
            break
        fi
        echo "⏳ Waiting for web service..."
        sleep 5
    done
'

# Clean up old images to save space
echo "🧹 Cleaning up old Docker images..."
docker image prune -f --filter "label=com.docker.compose.project=maybe" || true

# Show final status
echo "📊 Final deployment status:"
$DOCKER_COMPOSE ps

echo "📢 Deployment complete!"
echo "🌐 Application should be available at: http://localhost:${PORT:-2400}"

# Optional: Show recent logs
echo "📝 Recent application logs:"
$DOCKER_COMPOSE logs --tail=20 web