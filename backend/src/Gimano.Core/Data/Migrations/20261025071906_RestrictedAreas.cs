using Microsoft.EntityFrameworkCore.Migrations;
using NetTopologySuite.Geometries;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class RestrictedAreas : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "held_for_review",
                table: "reviews",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<bool>(
                name: "held_for_review",
                table: "community_places",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "restricted_areas",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    osm_id = table.Column<long>(type: "bigint", nullable: true),
                    curated = table.Column<bool>(type: "boolean", nullable: false),
                    @public = table.Column<bool>(name: "public", type: "boolean", nullable: false),
                    geom = table.Column<Polygon>(type: "geography (polygon, 4326)", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_restricted_areas", x => x.id);
                });

            migrationBuilder.CreateIndex(
                name: "ix_restricted_areas_geom",
                table: "restricted_areas",
                column: "geom")
                .Annotation("Npgsql:IndexMethod", "gist");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "restricted_areas");

            migrationBuilder.DropColumn(
                name: "held_for_review",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "held_for_review",
                table: "community_places");
        }
    }
}
