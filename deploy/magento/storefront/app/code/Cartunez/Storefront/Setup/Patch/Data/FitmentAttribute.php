<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Catalog\Model\Product;
use Magento\Catalog\Model\ResourceModel\Eav\Attribute;
use Magento\Eav\Setup\EavSetupFactory;
use Magento\Framework\Setup\ModuleDataSetupInterface;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Product attribute "cz_fitment": the vehicles a part fits, sent by the POS.
 * Searchable, so the Make/Model/Year finder can search for "marutisuzukiswift2020".
 */
class FitmentAttribute implements DataPatchInterface
{
    public function __construct(
        private readonly ModuleDataSetupInterface $moduleDataSetup,
        private readonly EavSetupFactory $eavSetupFactory
    ) {
    }

    public function apply(): self
    {
        $this->moduleDataSetup->getConnection()->startSetup();
        $eavSetup = $this->eavSetupFactory->create(['setup' => $this->moduleDataSetup]);
        if (!$eavSetup->getAttributeId(Product::ENTITY, 'cz_fitment')) {
            $eavSetup->addAttribute(Product::ENTITY, 'cz_fitment', [
                'type' => 'text',
                'label' => 'Vehicle fitment (from POS)',
                'input' => 'textarea',
                'required' => false,
                'global' => Attribute::SCOPE_GLOBAL,
                'visible' => true,
                'user_defined' => true,
                'searchable' => true,
                'filterable' => false,
                'comparable' => false,
                'visible_on_front' => false,
                'used_in_product_listing' => false,
                'is_used_in_grid' => false,
                'group' => 'General',
                'sort_order' => 900,
                'note' => 'Filled in by the Cartunez POS. Edit fitment in the POS, not here.',
            ]);
        }
        $this->moduleDataSetup->getConnection()->endSetup();
        return $this;
    }

    public static function getDependencies(): array
    {
        return [];
    }

    public function getAliases(): array
    {
        return [];
    }
}
