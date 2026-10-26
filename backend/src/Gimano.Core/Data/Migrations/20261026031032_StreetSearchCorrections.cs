using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class StreetSearchCorrections : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "street_original_name",
                table: "place_suggestions",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<long[]>(
                name: "street_way_ids",
                table: "place_suggestions",
                type: "bigint[]",
                nullable: false,
                defaultValue: new long[0]);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "street_original_name",
                table: "place_suggestions");

            migrationBuilder.DropColumn(
                name: "street_way_ids",
                table: "place_suggestions");
        }
    }
}
