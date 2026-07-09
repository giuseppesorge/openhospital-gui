/*
 * Open Hospital (www.open-hospital.org)
 * Copyright © 2006-2025 Informatici Senza Frontiere (info@informaticisenzafrontiere.org)
 *
 * Open Hospital is a free and open source software for healthcare data management.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * https://www.gnu.org/licenses/gpl-3.0-standalone.html
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package org.isf.admission.gui;

import java.awt.BorderLayout;
import java.awt.Dimension;
import java.awt.Frame;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import javax.swing.JButton;
import javax.swing.JDialog;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.JTabbedPane;
import javax.swing.JTable;
import javax.swing.table.DefaultTableModel;

import org.isf.generaldata.MessageBundle;
import org.isf.patient.dto.PatientExport;
import org.isf.patient.gui.PatientExportJson;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * Read-only, tab-per-category view of a patient full record (GDPR Art. 15, right of access). The aggregate
 * produced for OP-887 ({@link PatientExport}) is rendered generically from its JSON form: the patient object
 * as a field/value table, and each linked collection (admissions, OPDs, laboratories, ...) as its own table.
 */
public class PatientFullRecordDialog extends JDialog {

	private static final long serialVersionUID = 1L;

	private static final int MAX_CELL_LENGTH = 200;

	/** Technical / audit fields hidden from the read-only view (lower-cased JSON field names). */
	private static final Set<String> HIDDEN_FIELDS = Set.of(
		"createdby", "createddate", "lastmodifiedby", "lastmodifieddate", "active", "lock");

	public PatientFullRecordDialog(Frame owner, PatientExport export) throws JsonProcessingException {
		super(owner, MessageBundle.getMessage("angal.admission.patientfullrecord.title"), true);
		JsonNode root = new ObjectMapper().readTree(PatientExportJson.toJson(export));

		JTabbedPane tabbedPane = new JTabbedPane();
		Iterator<Map.Entry<String, JsonNode>> fields = root.fields();
		while (fields.hasNext()) {
			Map.Entry<String, JsonNode> field = fields.next();
			JsonNode node = field.getValue();
			if (node.isArray()) {
				tabbedPane.addTab(humanize(field.getKey()) + " (" + node.size() + ')', new JScrollPane(buildArrayTable(node)));
			} else {
				tabbedPane.addTab(humanize(field.getKey()), new JScrollPane(buildObjectTable(node)));
			}
		}

		JButton closeButton = new JButton(MessageBundle.getMessage("angal.common.close.btn"));
		closeButton.setMnemonic(MessageBundle.getMnemonic("angal.common.close.btn.key"));
		closeButton.addActionListener(actionEvent -> dispose());
		JPanel southPanel = new JPanel();
		southPanel.add(closeButton);

		getContentPane().setLayout(new BorderLayout());
		getContentPane().add(tabbedPane, BorderLayout.CENTER);
		getContentPane().add(southPanel, BorderLayout.SOUTH);
		setPreferredSize(new Dimension(900, 550));
		pack();
		setLocationRelativeTo(owner);
	}

	/**
	 * A single JSON object rendered as a two-column (field, value) read-only table.
	 */
	private JTable buildObjectTable(JsonNode object) {
		DefaultTableModel model = readOnlyModel(new Object[] {
			MessageBundle.getMessage("angal.admission.patientfullrecord.field.col"),
			MessageBundle.getMessage("angal.admission.patientfullrecord.value.col")
		});
		Iterator<Map.Entry<String, JsonNode>> fields = object.fields();
		while (fields.hasNext()) {
			Map.Entry<String, JsonNode> field = fields.next();
			if (isHidden(field.getKey())) {
				continue;
			}
			model.addRow(new Object[] { humanize(field.getKey()), render(field.getValue()) });
		}
		return new JTable(model);
	}

	/**
	 * A JSON array of records rendered as a read-only table whose columns are the union of the records' fields.
	 */
	private JTable buildArrayTable(JsonNode array) {
		Set<String> columns = new LinkedHashSet<>();
		for (JsonNode element : array) {
			if (element.isObject()) {
				element.fieldNames().forEachRemaining(name -> {
					if (!isHidden(name)) {
						columns.add(name);
					}
				});
			}
		}
		if (columns.isEmpty()) {
			DefaultTableModel model = readOnlyModel(new Object[] { MessageBundle.getMessage("angal.admission.patientfullrecord.value.col") });
			for (JsonNode element : array) {
				model.addRow(new Object[] { render(element) });
			}
			return new JTable(model);
		}
		List<String> columnList = new ArrayList<>(columns);
		DefaultTableModel model = readOnlyModel(columnList.stream().map(this::humanize).toArray());
		for (JsonNode element : array) {
			Object[] row = new Object[columnList.size()];
			for (int i = 0; i < columnList.size(); i++) {
				row[i] = render(element.get(columnList.get(i)));
			}
			model.addRow(row);
		}
		return new JTable(model);
	}

	private DefaultTableModel readOnlyModel(Object[] columns) {
		return new DefaultTableModel(columns, 0) {
			private static final long serialVersionUID = 1L;

			@Override
			public boolean isCellEditable(int row, int column) {
				return false;
			}
		};
	}

	private boolean isHidden(String fieldName) {
		return fieldName != null && HIDDEN_FIELDS.contains(fieldName.toLowerCase(Locale.ROOT));
	}

	/**
	 * Render a JSON value for a table cell: scalars as their text, a nested object by its description or name
	 * (falling back to its compact JSON), capped in length so a single cell never dominates the table.
	 */
	private String render(JsonNode value) {
		if (value == null || value.isNull() || value.isMissingNode()) {
			return "";
		}
		String text;
		if (value.isValueNode()) {
			text = value.asText();
		} else if (value.isObject() && value.hasNonNull("description")) {
			text = value.get("description").asText();
		} else if (value.isObject() && value.hasNonNull("name")) {
			text = value.get("name").asText();
		} else {
			text = value.toString();
		}
		if (text.length() > MAX_CELL_LENGTH) {
			text = text.substring(0, MAX_CELL_LENGTH) + '…';
		}
		return text;
	}

	/**
	 * Turn a camelCase JSON field name into a capitalized, space-separated label (e.g. {@code admDate} to
	 * {@code Adm Date}).
	 */
	private String humanize(String name) {
		if (name == null || name.isEmpty()) {
			return name;
		}
		StringBuilder result = new StringBuilder();
		result.append(Character.toUpperCase(name.charAt(0)));
		for (int i = 1; i < name.length(); i++) {
			char c = name.charAt(i);
			if (Character.isUpperCase(c)) {
				result.append(' ');
			}
			result.append(c);
		}
		return result.toString();
	}
}
