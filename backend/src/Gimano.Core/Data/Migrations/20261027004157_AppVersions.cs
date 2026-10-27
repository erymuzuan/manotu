using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class AppVersions : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "app_releases",
                columns: table => new
                {
                    platform = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    version = table.Column<string>(type: "character varying(30)", maxLength: 30, nullable: false),
                    first_seen_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    released_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_app_releases", x => new { x.platform, x.version });
                });

            migrationBuilder.CreateTable(
                name: "app_version_config",
                columns: table => new
                {
                    platform = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    min_version = table.Column<string>(type: "character varying(30)", maxLength: 30, nullable: true),
                    max_behind = table.Column<int>(type: "integer", nullable: false, defaultValue: 3),
                    store_url = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: true),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_app_version_config", x => x.platform);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "app_releases");

            migrationBuilder.DropTable(
                name: "app_version_config");
        }
    }
}
