<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Magento\Framework\App\ResourceConnection;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * "Search by Make, Model, Year": the vehicles come from the cz_fitment values
 * the POS sends with each published part ("V:Make|Model|from|to" lines).
 */
class VehicleFinder extends Template
{
    public function __construct(
        Context $context,
        private readonly ResourceConnection $resource,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    /**
     * @return array<string, array<string, int[]>> make => model => years (newest first)
     */
    public function getVehicles(): array
    {
        $db = $this->resource->getConnection();
        $entityType = $db->fetchOne(
            $db->select()->from($this->resource->getTableName('eav_entity_type'), 'entity_type_id')
                ->where('entity_type_code = ?', 'catalog_product')
        );
        $attributeId = $db->fetchOne(
            $db->select()->from($this->resource->getTableName('eav_attribute'), 'attribute_id')
                ->where('attribute_code = ?', 'cz_fitment')
                ->where('entity_type_id = ?', (int)$entityType)
        );
        if (!$attributeId) {
            return [];
        }
        $values = $db->fetchCol(
            $db->select()->from($this->resource->getTableName('catalog_product_entity_text'), 'value')
                ->where('attribute_id = ?', (int)$attributeId)
                ->where('store_id = ?', 0)
        );
        $tree = [];
        foreach ($values as $value) {
            foreach (preg_split('/\R/', (string)$value) ?: [] as $line) {
                if (strncmp($line, 'V:', 2) !== 0) {
                    continue;
                }
                [$make, $model, $from, $to] = array_pad(explode('|', substr($line, 2)), 4, '');
                $from = (int)$from;
                $to = (int)$to;
                if ($make === '' || $model === '' || $from < 1900 || $to < $from || $to - $from > 60) {
                    continue;
                }
                for ($year = $from; $year <= $to; $year++) {
                    $tree[$make][$model][$year] = true;
                }
            }
        }
        ksort($tree, SORT_NATURAL | SORT_FLAG_CASE);
        foreach ($tree as $make => $models) {
            ksort($models, SORT_NATURAL | SORT_FLAG_CASE);
            foreach ($models as $model => $years) {
                $list = array_keys($years);
                rsort($list);
                $models[$model] = $list;
            }
            $tree[$make] = $models;
        }
        return $tree;
    }

    public function getVehiclesJson(): string
    {
        return (string)json_encode(
            $this->getVehicles(),
            JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_UNICODE
        );
    }
}
